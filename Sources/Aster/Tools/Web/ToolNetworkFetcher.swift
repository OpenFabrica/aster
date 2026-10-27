// `net.fetch` 的请求校验与原生代发。页面自己不能联网（CSP `connect-src 'none'`），只能经这里访问已授权域名。
import AsterCore
import Foundation

/// 校验通过、可以发出的请求。
struct ToolFetchRequest: Equatable, Sendable {
  let url: URL
  let method: String
  let headers: [String: String]
  let body: Data?
}

/// 交回页面的响应。`body` 按 UTF-8 解码（非法字节替换）。
struct ToolFetchResponse: Equatable, Sendable {
  let status: Int
  /// 头名称统一小写。
  let headers: [String: String]
  let body: String

  /// 回给页面的 `{status, headers, body}`。
  var jsonValue: JSONValue {
    .object([
      "status": .number(Double(status)),
      "headers": .object(headers.mapValues(JSONValue.string)),
      "body": .string(body),
    ])
  }
}

/// `net.fetch` 的参数规则。
enum ToolFetchPolicy {
  static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
  static let maximumHeaderCount = 32
  static let maximumURLBytes = 8_192
  static let maximumHeaderValueBytes = 8_192
  /// 不允许页面设置的请求头（小写）：Host / Cookie 会绕过域名与无 cookie 的约束，
  /// 其余是 URLSession 自己管理的连接与分帧头，手动设置会让请求出错。
  static let forbiddenHeaders: Set<String> = [
    "host", "cookie", "cookie2", "connection", "content-length", "keep-alive", "proxy-authorization",
    "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
  ]

  /// HTTP 头名称允许的 token 字符（RFC 9110）。
  private static let tokenCharacters = CharacterSet(
    charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

  /// 地址能否访问：必须是 https、没有用户信息，主机匹配授权域名。重定向目标也用它判断。
  static func allows(_ url: URL?, allowedDomains: [String]) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
      let host = url.host(percentEncoded: false), !host.isEmpty
    else { return false }
    return ToolBridgeValidator.isHostAllowed(host, patterns: allowedDomains)
  }

  /// 把页面参数 `{url, method?, headers?, body?}` 校验成请求；不合格抛 `ToolBridgeError`。
  static func validate(_ params: [String: JSONValue], allowedDomains: [String]) throws -> ToolFetchRequest {
    let text = try ToolBridgeParams.requiredString(params, "url", maximumBytes: maximumURLBytes)
    let hasInvalidCharacter = text.unicodeScalars.contains {
      CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
    }
    guard !hasInvalidCharacter, let url = URL(string: text), url.scheme?.lowercased() == "https",
      url.host(percentEncoded: false) != nil
    else { throw ToolBridgeError.invalidParams(L("只允许 https 地址")) }
    guard allows(url, allowedDomains: allowedDomains) else {
      throw ToolBridgeError.permissionDenied(.network)
    }
    let method = (try ToolBridgeValidator.string(params, "method", maximumBytes: 16, required: false) ?? "GET")
      .uppercased()
    guard allowedMethods.contains(method) else { throw ToolBridgeError.invalidParams("method") }
    let headers = try validateHeaders(params["headers"])
    let body = try ToolBridgeValidator.string(
      params, "body", maximumBytes: ToolBridgeProtocol.maximumTextBytes, required: false)
    if body != nil, method == "GET" || method == "HEAD" {
      throw ToolBridgeError.invalidParams("body")
    }
    return ToolFetchRequest(url: url, method: method, headers: headers, body: body.map { Data($0.utf8) })
  }

  /// 请求头：对象、值都是字符串、数量与长度有上限、名称是合法 token、不能是禁用头、值里不能有换行。
  private static func validateHeaders(_ value: JSONValue?) throws -> [String: String] {
    guard let value, !value.isNull else { return [:] }
    guard let members = value.objectValue, members.count <= maximumHeaderCount else {
      throw ToolBridgeError.invalidParams("headers")
    }
    var headers: [String: String] = [:]
    for (name, raw) in members {
      guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
        !forbiddenHeaders.contains(name.lowercased()), !name.lowercased().hasPrefix("proxy-")
      else { throw ToolBridgeError.invalidParams(L("不允许的请求头：\(name)")) }
      guard let headerValue = raw.stringValue, headerValue.utf8.count <= maximumHeaderValueBytes,
        !headerValue.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
      else { throw ToolBridgeError.invalidParams(L("请求头的值无效：\(name)")) }
      headers[name] = headerValue
    }
    return headers
  }
}

/// 代发请求：无 cookie、无缓存、无保存凭据的 ephemeral 会话，超时与响应大小有上限。
enum ToolNetworkFetcher {
  /// 在 `base` 上关掉 cookie、缓存与凭据存储，设置超时。测试可以传带桩协议的配置。
  static func makeSession(base: URLSessionConfiguration = .ephemeral) -> URLSession {
    base.httpCookieAcceptPolicy = .never
    base.httpShouldSetCookies = false
    base.httpCookieStorage = nil
    base.urlCache = nil
    base.urlCredentialStorage = nil
    base.requestCachePolicy = .reloadIgnoringLocalCacheData
    base.timeoutIntervalForRequest = ToolBridgeProtocol.fetchTimeout
    base.timeoutIntervalForResource = ToolBridgeProtocol.fetchTimeout
    base.waitsForConnectivity = false
    return URLSession(configuration: base)
  }

  /// 发出请求并流式读取响应；正文超过 `maximumBytes` 立即中止。不要在主线程等待它的 CPU 部分。
  static func perform(
    _ request: ToolFetchRequest,
    session: URLSession,
    allowedDomains: [String],
    maximumBytes: Int = ToolBridgeProtocol.maximumFetchResponseBytes
  ) async throws -> ToolFetchResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpShouldHandleCookies = false
    urlRequest.httpBody = request.body
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    let redirectGuard = ToolFetchRedirectGuard(allowedDomains: allowedDomains)
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirectGuard)
    } catch {
      throw mapError(error)
    }
    guard let http = response as? HTTPURLResponse else { throw ToolBridgeError.failed(L("不是 HTTP 响应")) }
    if http.expectedContentLength > Int64(maximumBytes) {
      bytes.task.cancel()
      throw ToolBridgeError.payloadTooLarge
    }
    var body: [UInt8] = []
    body.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(maximumBytes)))))
    do {
      for try await byte in bytes {
        body.append(byte)
        if body.count > maximumBytes {
          bytes.task.cancel()
          throw ToolBridgeError.payloadTooLarge
        }
      }
    } catch let error as ToolBridgeError {
      throw error
    } catch {
      throw mapError(error)
    }
    var headers: [String: String] = [:]
    for (name, value) in http.allHeaderFields {
      guard let name = name as? String else { continue }
      headers[name.lowercased()] = value as? String ?? "\(value)"
    }
    return ToolFetchResponse(
      status: http.statusCode, headers: headers, body: String(decoding: body, as: UTF8.self))
  }

  /// 把 URLSession 的错误转成给页面看的桥接错误。
  private static func mapError(_ error: any Error) -> ToolBridgeError {
    if let error = error as? ToolBridgeError { return error }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut: return .failed(L("请求超时"))
      case .cancelled: return .unavailable(L("请求已取消"))
      default: break
      }
    }
    return .failed(L("网络请求失败：\(error.localizedDescription)"))
  }
}

/// 单个请求的任务代理：只跟随指向授权域名的 https 重定向；拒绝 HTTP 认证质询，不让页面借用系统保存的凭据。
/// 只有不可变的 `let` 成员，所以可以安全地在 URLSession 的代理队列上使用。
final class ToolFetchRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  let allowedDomains: [String]

  init(allowedDomains: [String]) {
    self.allowedDomains = allowedDomains
  }

  /// 重定向到未授权的地址时不跟随：把 3xx 响应原样交回页面，由页面看 `location` 头。
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(ToolFetchPolicy.allows(request.url, allowedDomains: allowedDomains) ? request : nil)
  }

  /// 服务器证书走系统默认校验；HTTP 认证、客户端证书一律不提供凭据。
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.rejectProtectionSpace, nil)
    }
  }
}
