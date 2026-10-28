// 桥接请求的解析与授权：版本、方法、params 结构、消息大小，方法与权限的对应表，错误码与协议常量。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolBridgeValidator")
struct ToolBridgeValidatorTests {
  /// 把 JSON 文本解析成 Foundation 对象，模拟 WebKit 传来的消息体。
  private func body(_ json: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
  }

  /// 解析 `v`/`method`/`params` 等字段拼成的消息体。
  private func parse(_ fields: [String: Any]) throws -> ToolBridgeRequest {
    try ToolBridgeValidator.parse(fields)
  }

  /// 解析并返回抛出的 `ToolBridgeError`；解析成功时返回 nil。
  private func failure(_ body: Any) -> ToolBridgeError? {
    do {
      _ = try ToolBridgeValidator.parse(body)
      return nil
    } catch {
      return error as? ToolBridgeError
    }
  }

  // MARK: 解析

  /// 最小请求只要 `v` 与方法；params 缺省或 null 时是空对象；其它顶层字段忽略。
  @Test func parseAcceptsMinimalRequestAndIgnoresExtraFields() throws {
    #expect(try parse(["v": 1, "method": "tool.input"]) == ToolBridgeRequest(method: .toolInput))
    #expect(try parse(["v": 1, "method": "ui.close", "params": NSNull()]) == ToolBridgeRequest(method: .close))
    #expect(try parse(["v": 1, "method": "ui.close", "id": 5, "x": [1, 2]]) == ToolBridgeRequest(method: .close))
  }

  /// params 是对象时原样带上，嵌套的数字、布尔与 null 都保留类型。
  @Test func parseKeepsObjectParams() throws {
    let request = try parse([
      "v": 1, "method": "storage.set", "params": ["key": "k", "value": ["a": [1, true, NSNull(), "s"]]],
    ])
    #expect(request.method == .storageSet)
    #expect(request.params == ["key": "k", "value": ["a": [1, true, nil, "s"]]])
  }

  /// params 只能缺省、null 或对象；数组、字符串、数字、布尔都是 `invalid_params`。
  @Test(arguments: ["[]", "[1]", #""text""#, "5", "1.5", "true", "false"])
  func parseRejectsNonObjectParams(params: String) throws {
    let message = try body(#"{"v":1,"method":"storage.get","params":"# + params + "}")
    #expect(failure(message) == .invalidParams("params"))
  }

  /// `v` 必须恰好是数字 1：缺失、其它数字、小数、布尔、字符串、null、数组、对象都是不支持的版本；版本检查先于方法检查。
  @Test(arguments: [
    #"{"method":"ui.close"}"#, #"{"v":0,"method":"ui.close"}"#, #"{"v":2,"method":"ui.close"}"#,
    #"{"v":-1,"method":"ui.close"}"#, #"{"v":1.5,"method":"ui.close"}"#, #"{"v":true,"method":"ui.close"}"#,
    #"{"v":false,"method":"ui.close"}"#, #"{"v":"1","method":"ui.close"}"#, #"{"v":null,"method":"ui.close"}"#,
    #"{"v":[1],"method":"ui.close"}"#, #"{"v":{"a":1},"method":"ui.close"}"#, #"{"v":2,"method":"no.such.method"}"#,
  ])
  func parseRejectsUnsupportedVersions(json: String) throws {
    #expect(failure(try body(json)) == .unsupportedVersion)
  }

  /// `method` 不是字符串：缺失、数字、null、布尔、数组、对象都报 `invalid_params("method")`。
  @Test(arguments: [
    #"{"v":1}"#, #"{"v":1,"method":1}"#, #"{"v":1,"method":null}"#, #"{"v":1,"method":true}"#,
    #"{"v":1,"method":["tool.input"]}"#, #"{"v":1,"method":{"a":1}}"#,
  ])
  func parseRejectsNonStringMethod(json: String) throws {
    #expect(failure(try body(json)) == .invalidParams("method"))
  }

  /// 未知方法（含空串、大小写或空白不一致）报 `unknown_method` 并带上名字；名字最多回显 64 个字符。
  @Test func parseRejectsUnknownMethodAndEchoesBoundedName() {
    for name in ["", "nope", "Tool.Input", "tool.input ", "storage", "ui.setheight"] {
      #expect(failure(["v": 1, "method": name] as [String: Any]) == .unknownMethod(name), "\(name)")
    }
    let long = String(repeating: "a", count: 100)
    #expect(failure(["v": 1, "method": long] as [String: Any]) == .unknownMethod(String(repeating: "a", count: 64)))
    let cjk = String(repeating: "你", count: 100)
    #expect(failure(["v": 1, "method": cjk] as [String: Any]) == .unknownMethod(String(repeating: "你", count: 64)))
  }

  /// 每个已知方法都能按原始值解析。
  @Test(arguments: ToolBridgeMethod.allCases)
  func parseAcceptsEveryKnownMethod(method: ToolBridgeMethod) throws {
    #expect(try parse(["v": 1, "method": method.rawValue]).method == method)
  }

  /// 消息体不是 JSON 对象（数组、标量、null、含非法值或非字符串键的字典）时报 `invalid_params`。
  @Test func parseRejectsBodiesThatAreNotJSONObjects() {
    let bodies: [Any] = [
      [1, 2], "text", 5, true, NSNull(),
      ["v": 1, "method": "ui.close", "x": Double.nan] as [String: Any],
      ["v": 1, "method": "ui.close", "x": Date(timeIntervalSince1970: 0)] as [String: Any],
      [1: "a"] as [Int: String],
    ]
    for body in bodies {
      var isInvalidParams = false
      if case .invalidParams? = failure(body) { isInvalidParams = true }
      #expect(isInvalidParams, "\(body)")
    }
  }

  /// 序列化后恰好 2 MiB 可以，多 1 字节报 `payload_too_large`；大小检查先于版本检查。
  @Test func parseEnforcesRequestSizeLimit() throws {
    // 用 params 里的填充串把序列化后的大小调到想要的字节数。
    func message(padding: Int, version: Int = 1) -> [String: Any] {
      ["v": version, "method": "ui.close", "params": ["pad": String(repeating: "a", count: padding)]]
    }
    let limit = ToolBridgeProtocol.maximumRequestBytes
    #expect(limit == 2 * 1_048_576)
    let overhead = try JSONSerialization.data(withJSONObject: message(padding: 0)).count
    let atLimit = message(padding: limit - overhead)
    #expect(try JSONSerialization.data(withJSONObject: atLimit).count == limit)
    #expect(try parse(atLimit).method == .close)
    #expect(failure(message(padding: limit - overhead + 1)) == .payloadTooLarge)
    #expect(failure(message(padding: limit, version: 9)) == .payloadTooLarge)
  }

  // MARK: 授权与方法表

  /// 不需要权限的方法在什么都没授予时也放行。
  @Test(arguments: ToolBridgeMethod.allCases.filter { $0.requiredPermission == nil })
  func authorizeAllowsMethodsWithoutPermission(method: ToolBridgeMethod) throws {
    try ToolBridgeValidator.authorize(ToolBridgeRequest(method: method), granted: [])
  }

  /// 需要权限的方法：什么都没授予或只授予了别的权限都拒绝，授予了所需权限才放行。
  @Test(arguments: ToolBridgeMethod.allCases.filter { $0.requiredPermission != nil })
  func authorizeRequiresTheDeclaredPermission(method: ToolBridgeMethod) throws {
    let permission = try #require(method.requiredPermission)
    let request = ToolBridgeRequest(method: method)
    let others = Set(ToolPermission.allCases).subtracting([permission])
    #expect(throws: ToolBridgeError.permissionDenied(permission)) { try ToolBridgeValidator.authorize(request, granted: []) }
    #expect(throws: ToolBridgeError.permissionDenied(permission)) { try ToolBridgeValidator.authorize(request, granted: others) }
    try ToolBridgeValidator.authorize(request, granted: [permission])
    try ToolBridgeValidator.authorize(request, granted: Set(ToolPermission.allCases))
  }

  /// 方法原始值与所需权限同开发文档的方法表一致；`exec` 不对应任何桥接方法。
  @Test func methodTableMatchesDocumentedPermissions() throws {
    let table: [(String, ToolPermission?)] = [
      ("tool.input", nil), ("ui.setHeight", nil), ("ui.close", nil), ("storage.get", nil), ("storage.set", nil),
      ("storage.remove", nil), ("storage.keys", nil), ("secureStorage.get", nil), ("secureStorage.set", nil),
      ("secureStorage.remove", nil), ("secureStorage.keys", nil), ("shell.openURL", nil),
      ("clipboard.readText", .clipboardRead), ("clipboard.writeText", .clipboardWrite),
      ("terminal.insert", .terminalInsert), ("terminal.selection", .terminalRead),
      ("files.pick", .filesRead), ("files.read", .filesRead), ("net.fetch", .network), ("notify", .notify),
    ]
    #expect(Set(table.map(\.0)) == Set(ToolBridgeMethod.allCases.map(\.rawValue)))
    for (name, permission) in table {
      let method = try #require(ToolBridgeMethod(rawValue: name), "\(name)")
      #expect(method.requiredPermission == permission, "\(name)")
    }
    #expect(!ToolBridgeMethod.allCases.contains { $0.requiredPermission == .exec })
  }

  // MARK: 错误与常量

  /// 错误码是 snake_case，回复字符串是 `"<code>: <message>"`；unavailable 与 failed 的原因原样带出。
  @Test func errorCodesAndReplyStrings() {
    let table: [(ToolBridgeError, String)] = [
      (.unsupportedVersion, "unsupported_version"), (.unknownMethod("x"), "unknown_method"),
      (.invalidParams("x"), "invalid_params"), (.permissionDenied(.network), "permission_denied"),
      (.payloadTooLarge, "payload_too_large"), (.rateLimited, "rate_limited"),
      (.unavailable("x"), "unavailable"), (.failed("x"), "failed"),
    ]
    #expect(Set(table.map(\.1)).count == table.count)
    for (error, code) in table {
      #expect(error.code == code)
      #expect(!error.message.isEmpty)
      #expect(error.replyString == "\(code): \(error.message)")
    }
    #expect(ToolBridgeError.unavailable("no pane").replyString == "unavailable: no pane")
    #expect(ToolBridgeError.failed("boom").replyString == "failed: boom")
    #expect(ToolBridgeError.unknownMethod("foo").message.contains("foo"))
    #expect(ToolBridgeError.invalidParams("key").message.contains("key"))
    #expect(ToolBridgeError.permissionDenied(.network).message.contains("network"))
  }

  /// 协议常量与开发文档「网页工具」一节一致。
  @Test func protocolConstantsMatchDocumentedValues() {
    #expect(ToolBridgeProtocol.version == 1)
    #expect(ToolBridgeProtocol.messageHandlerName == "aster")
    #expect(ToolBridgeProtocol.scheme == "aster-plugin")
    #expect(ToolBridgeProtocol.maximumTextBytes == 1_048_576)
    #expect(ToolBridgeProtocol.maximumStorageKeyBytes == 128)
    #expect(ToolBridgeProtocol.maximumStorageBytes == 5 * 1_048_576)
    #expect(ToolBridgeProtocol.maximumFileReadBytes == 10 * 1_048_576)
    #expect(ToolBridgeProtocol.maximumFetchResponseBytes == 5 * 1_048_576)
    #expect(ToolBridgeProtocol.fetchTimeout == 15)
    #expect(ToolBridgeProtocol.maximumCallsPerSecond == 50)
    #expect(
      ToolBridgeProtocol.contentSecurityPolicy
        == "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
        + "font-src 'self' data:; media-src 'self' data: blob:; connect-src 'none'; object-src 'none'; "
        + "frame-src 'none'; base-uri 'none'; form-action 'none'")
  }
}
