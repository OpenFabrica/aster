// net.fetch：参数校验（https、授权主机、方法、请求头、请求体）、重定向守卫与响应大小上限。
// 网络层全部用桩协议，不真的联网。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 按路径给固定响应的桩协议，只处理 `stub.example.com`：`/big` 返回 4 KiB 正文，
/// `/declared` 在响应头里声明 4 KiB，其余返回一个小 JSON。
final class ToolFetchStubProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "stub.example.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    var headers = ["Content-Type": "application/json", "X-Custom": "yes"]
    let body: Data
    switch url.path {
    case "/big":
      body = Data(repeating: 0x61, count: 4_096)
    case "/declared":
      body = Data(repeating: 0x61, count: 4_096)
      headers["Content-Length"] = "4096"
    default:
      body = Data(#"{"ok":true}"#.utf8)
    }
    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private let domains = ["api.example.com", "*.cdn.example.com"]

/// 校验参数，返回错误码；通过时返回 nil。
private func validationError(_ params: [String: JSONValue]) -> String? {
  do {
    _ = try ToolFetchPolicy.validate(params, allowedDomains: domains)
    return nil
  } catch let error as ToolBridgeError {
    return error.code
  } catch {
    return "unexpected"
  }
}

@Test("只允许 https 与授权主机；方法、请求头与请求体按规则校验")
func toolFetchPolicyValidatesRequests() throws {
  #expect(validationError(["url": "http://api.example.com/"]) == "invalid_params")
  #expect(validationError(["url": "ftp://api.example.com/"]) == "invalid_params")
  #expect(validationError(["url": "https://api.example.com/ x"]) == "invalid_params")
  #expect(validationError(["url": "https://evil.example.org/"]) == "permission_denied")
  #expect(validationError(["url": "https://cdn.example.com/"]) == "permission_denied")
  #expect(validationError(["url": "https://api.example.com.evil.org/"]) == "permission_denied")
  #expect(validationError(["url": "https://user:pw@api.example.com/"]) == "permission_denied")
  #expect(validationError(["url": "https://img.cdn.example.com/a.png"]) == nil)

  let base: [String: JSONValue] = ["url": "https://api.example.com/"]
  func with(_ key: String, _ value: JSONValue) -> [String: JSONValue] { base.merging([key: value]) { $1 } }
  #expect(validationError(with("method", "TRACE")) == "invalid_params")
  #expect(validationError(with("body", "x")) == "invalid_params")
  #expect(validationError(with("headers", ["Host": "evil.org"])) == "invalid_params")
  #expect(validationError(with("headers", ["cookie": "a=b"])) == "invalid_params")
  #expect(validationError(with("headers", ["Proxy-Anything": "x"])) == "invalid_params")
  #expect(validationError(with("headers", ["X-A": "a\r\nInjected: 1"])) == "invalid_params")
  #expect(validationError(with("headers", ["Bad Name": "x"])) == "invalid_params")
  let tooMany = JSONValue.object(Dictionary(uniqueKeysWithValues: (0...32).map { ("X-\($0)", JSONValue.string("v")) }))
  #expect(validationError(with("headers", tooMany)) == "invalid_params")

  let request = try ToolFetchPolicy.validate(
    ["url": "https://api.example.com/v1", "method": "post", "headers": ["Authorization": "Bearer t"], "body": "{}"],
    allowedDomains: domains)
  #expect(request.method == "POST")
  #expect(request.headers == ["Authorization": "Bearer t"])
  #expect(request.body == Data("{}".utf8))
}

@Test("桥接层：没有 network 权限、非 https、未授权主机都在联网前被拒")
@MainActor
func toolBridgeFetchRejectsBeforeNetworking() async throws {
  let directory = try makeTemporaryPluginDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let plugin = makeWebToolPlugin(directory: directory, permissions: [.network], network: ["api.example.com"])
  let bridge = ToolBridge(plugin: plugin, services: FakeToolBridgeServices())

  #expect(await callBridge(bridge, "net.fetch", ["url": "http://api.example.com/"]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "net.fetch", ["url": "https://other.example.com/"]).errorCode == "permission_denied")

  // 授予了但清单不再声明的域名同样不能访问。
  let narrowed = makeWebToolPlugin(
    directory: directory, permissions: [.network], network: ["api.example.com"],
    grantedDomains: ["api.example.com", "old.example.com"])
  let narrowedBridge = ToolBridge(plugin: narrowed, services: FakeToolBridgeServices())
  #expect(narrowedBridge.effectiveNetworkDomains == ["api.example.com"])
  #expect(
    await callBridge(narrowedBridge, "net.fetch", ["url": "https://old.example.com/"]).errorCode
      == "permission_denied")
}

@Test("重定向只跟随到授权主机的 https 地址")
func toolFetchRedirectGuardFollowsAllowedHostsOnly() async throws {
  let redirectGuard = ToolFetchRedirectGuard(allowedDomains: domains)
  let session = URLSession(configuration: .ephemeral)
  defer { session.invalidateAndCancel() }
  let origin = try #require(URL(string: "https://api.example.com/a"))
  let task = session.dataTask(with: origin)
  let response = try #require(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))

  /// 模拟一次重定向，返回守卫是否放行。
  func follows(_ target: String) async throws -> Bool {
    let request = URLRequest(url: try #require(URL(string: target)))
    return await withCheckedContinuation { continuation in
      redirectGuard.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
        continuation.resume(returning: $0 != nil)
      }
    }
  }
  #expect(try await follows("https://api.example.com/b"))
  #expect(try await follows("https://img.cdn.example.com/x.png"))
  #expect(try await !follows("http://api.example.com/b"))
  #expect(try await !follows("https://evil.example.org/"))
  #expect(try await !follows("https://user:pw@api.example.com/"))
}

@Test("响应正文超过上限时中止，声明的长度超过上限直接拒绝；正常响应头名转小写")
func toolFetchLimitsResponseSize() async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ToolFetchStubProtocol.self]
  let session = ToolNetworkFetcher.makeSession(base: configuration)
  defer { session.invalidateAndCancel() }
  let allowed = ["stub.example.com"]

  /// 对桩主机的某个路径发 GET。
  func get(_ path: String) throws -> ToolFetchRequest {
    ToolFetchRequest(
      url: try #require(URL(string: "https://stub.example.com\(path)")), method: "GET", headers: [:], body: nil)
  }
  await #expect(throws: ToolBridgeError.payloadTooLarge) {
    try await ToolNetworkFetcher.perform(get("/big"), session: session, allowedDomains: allowed, maximumBytes: 1_024)
  }
  await #expect(throws: ToolBridgeError.payloadTooLarge) {
    try await ToolNetworkFetcher.perform(
      get("/declared"), session: session, allowedDomains: allowed, maximumBytes: 1_024)
  }
  let ok = try await ToolNetworkFetcher.perform(
    get("/ok"), session: session, allowedDomains: allowed, maximumBytes: 1_024)
  #expect(ok.status == 200)
  #expect(ok.headers["x-custom"] == "yes")
  #expect(ok.body == #"{"ok":true}"#)
  #expect(ok.jsonValue["status"] == 200)
}
