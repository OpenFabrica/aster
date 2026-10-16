// `aster mcp` 的协议处理器：把 MCP 的 initialize / tools/list / tools/call 映射到
// `host.*` 控制方法。纯逻辑，不做 IO；控制调用由调用方注入，便于单测。
import Foundation

/// App 不可达（socket 连不上、拉起后仍无响应）。注入的控制调用用它与服务端错误区分。
public struct AgentHostMCPUnreachableError: Error, Equatable, Sendable {
  public var message: String

  /// 构造错误；`message` 是客户端侧的原因（会原样展示给 agent）。
  public init(message: String) { self.message = message }
}

/// MCP 工具层的状态与分发。
///
/// 会话键由进程启动时注入（`mcp:<UUID>`）：同一个 MCP server 进程的所有调用共用一个
/// 授权与终端复用的键；`clientInfo.name` 只进审计。
public struct AgentHostMCPTools: Sendable {
  /// 注入的控制调用：方法名 + params → result。服务端错误抛 `AsterControlError`，
  /// App 不可达抛 `AgentHostMCPUnreachableError`。
  public typealias ControlCall = (_ method: String, _ params: JSONValue) throws -> JSONValue

  /// 与客户端握手的 MCP 协议版本（与 aster-memory-mcp 一致）。
  public static let protocolVersion = "2025-06-18"
  /// `clientInfo.name` 缺失时写进审计的客户端名。
  public static let fallbackClientName = "mcp"

  public let sessionKey: String
  public let callerPane: String?
  /// initialize 时记录的客户端名（已清洗）。
  public private(set) var clientName: String?

  /// `callerPane` 不合法（过长、含控制字符）时直接丢弃：环境变量坏了不该让每次调用都失败。
  public init(sessionKey: String, callerPane: String?) {
    self.sessionKey = sessionKey
    if let callerPane, !callerPane.isEmpty,
      (try? AgentHostCaller(session: "x", callerPane: callerPane).validate()) != nil
    {
      self.callerPane = callerPane
    } else {
      self.callerPane = nil
    }
  }

  /// 本进程发往服务端的调用方身份。
  public var caller: AgentHostCaller {
    AgentHostCaller(session: sessionKey, client: clientName ?? Self.fallbackClientName, callerPane: callerPane)
  }

  /// 处理一条请求；返回 nil 表示 notification（无 id），不回包。
  public mutating func handle(_ request: JSONRPCRequest, call: ControlCall) -> JSONRPCResponse? {
    switch request.method {
    case "initialize":
      clientName = Self.sanitizedClientName(request.params?["clientInfo"]?["name"]?.stringValue)
      return JSONRPCResponse(
        id: request.id,
        result: .object([
          "protocolVersion": .string(Self.protocolVersion),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object(["name": "aster", "version": "0.1.0"]),
          "instructions": .string(AgentHostMCPToolCatalog.instructions),
        ]))
    case "notifications/initialized", "notifications/cancelled":
      return nil
    case "ping":
      return JSONRPCResponse(id: request.id, result: .object([:]))
    case "tools/list":
      return JSONRPCResponse(id: request.id, result: .object(["tools": .array(AgentHostMCPToolCatalog.listPayload)]))
    case "tools/call":
      // tools/call 理应带 id；万一是 notification 也不回包。
      guard request.id != nil else { return nil }
      return JSONRPCResponse(id: request.id, result: callTool(request.params, call: call))
    default:
      guard request.id != nil else { return nil }
      return JSONRPCResponse(
        id: request.id, error: JSONRPCError(code: -32601, message: "method not found: \(request.method)"))
    }
  }

  /// 清洗 `clientInfo.name`：去控制字符、trim、按 UTF-8 截到 64 字节；空串视为缺失。
  static func sanitizedClientName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let cleaned = AgentHostMCPArguments.sanitize(raw, maximumBytes: AgentHostLimits.maximumClientBytes)
    return cleaned.isEmpty ? nil : cleaned
  }

  // MARK: - tools/call

  /// 执行一个工具，产出 MCP tool result（成功或 `isError`）。
  private func callTool(_ params: JSONValue?, call: ControlCall) -> JSONValue {
    let name = AgentHostMCPArguments.sanitize(params?["name"]?.stringValue ?? "", maximumBytes: 128)
    guard AgentHostMCPToolCatalog.names.contains(name) else {
      return AgentHostMCPRendering.error("unknown tool: \(name)")
    }
    let arguments = params?["arguments"]
    do {
      let request = try controlRequest(tool: name, arguments: arguments)
      let result = try call(request.method, request.params)
      return AgentHostMCPRendering.success(tool: name, result: result)
    } catch let error as AgentHostMCPArgumentError {
      return AgentHostMCPRendering.error("invalid arguments: \(error.message)")
    } catch let error as AsterControlError {
      return AgentHostMCPRendering.controlError(error, tool: name)
    } catch let error as AgentHostMCPUnreachableError {
      return AgentHostMCPRendering.unreachable(error)
    } catch {
      return AgentHostMCPRendering.error("aster: \(error)")
    }
  }

  /// 工具参数 → 控制方法与 params。
  ///
  /// 先在本地用协议类型的 `validate()` 过一遍：参数错误立即以可读文案返回，
  /// 不必为一个必然失败的请求连 socket（甚至拉起 App）。
  func controlRequest(tool: String, arguments: JSONValue?) throws -> (method: String, params: JSONValue) {
    let arguments = try AgentHostMCPArguments.object(arguments)
    switch tool {
    case AgentHostMCPToolCatalog.Name.listHosts:
      return ("host.list", .object([:]))
    case AgentHostMCPToolCatalog.Name.hostExec:
      // 某些客户端会把多行脚本写成 CRLF；CR 在行编辑器里是回车键，统一换成 LF。
      let command = try AgentHostMCPArguments.requiredRawString(arguments, "command")
        .replacingOccurrences(of: "\r\n", with: "\n")
      let params = HostExecParams(
        host: try AgentHostMCPArguments.requiredString(arguments, "host"),
        command: command,
        agent: caller,
        reason: AgentHostMCPArguments.optionalString(arguments, "reason", maximumBytes: AgentHostLimits.maximumReasonBytes),
        timeoutMs: try timeoutMilliseconds(arguments))
      return (AgentHostControlMethod.hostExec.rawValue, try encode(params))
    case AgentHostMCPToolCatalog.Name.hostWait:
      let params = HostWaitParams(
        commandID: try AgentHostMCPArguments.requiredString(arguments, "command_id"),
        agent: caller, timeoutMs: try timeoutMilliseconds(arguments))
      return (AgentHostControlMethod.hostWait.rawValue, try encode(params))
    case AgentHostMCPToolCatalog.Name.hostRead:
      let params = HostReadParams(
        host: try AgentHostMCPArguments.requiredString(arguments, "host"), agent: caller,
        lines: try AgentHostMCPArguments.integer(arguments, "lines", range: 1...AgentHostLimits.maximumReadLines))
      return (AgentHostControlMethod.hostRead.rawValue, try encode(params))
    case AgentHostMCPToolCatalog.Name.hostInterrupt:
      let params = HostInterruptParams(host: try AgentHostMCPArguments.requiredString(arguments, "host"), agent: caller)
      return (AgentHostControlMethod.hostInterrupt.rawValue, try encode(params))
    case AgentHostMCPToolCatalog.Name.hostClose:
      let params = HostCloseParams(host: try AgentHostMCPArguments.requiredString(arguments, "host"), agent: caller)
      return (AgentHostControlMethod.hostClose.rawValue, try encode(params))
    default:
      throw AgentHostMCPArgumentError("unknown tool: \(tool)")
    }
  }

  /// `timeout_seconds`（1-50，默认 40）→ `timeout_ms`。
  private func timeoutMilliseconds(_ arguments: [String: JSONValue]) throws -> Int {
    let seconds = try AgentHostMCPArguments.integer(
      arguments, "timeout_seconds", range: AgentHostMCPToolCatalog.timeoutSecondsRange)
    return (seconds ?? AgentHostMCPToolCatalog.defaultTimeoutSeconds) * 1_000
  }

  /// 本地校验后编码；校验失败转成参数错误（文案来自协议层）。
  private func encode<T: Encodable & AsterControlValidatable>(_ params: T) throws -> JSONValue {
    do {
      try params.validate()
    } catch let error as AsterControlError {
      throw AgentHostMCPArgumentError(error.message)
    }
    return try JSONValue(encoding: params)
  }
}

/// 工具参数错误：以 `isError` tool result 返回，让 agent 看到哪个参数错了并自行修正。
struct AgentHostMCPArgumentError: Error {
  let message: String

  /// 构造错误。
  init(_ message: String) { self.message = message }
}

/// 工具参数的取值与清洗。参数来自外部 agent，一律视为不可信输入。
enum AgentHostMCPArguments {
  /// 宽松的单值上限：主机名、command_id 等标识符远小于它，协议层再做精确校验。
  static let maximumValueBytes = 512

  /// `arguments` 必须是对象或缺省。
  static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
    switch value {
    case nil, .null?: return [:]
    case .object(let members)?: return members
    default: throw AgentHostMCPArgumentError("arguments must be an object")
    }
  }

  /// 必需的单行字符串：trim 后非空；含控制字符时报错而不是悄悄改写（主机名改了就指向别处）。
  static func requiredString(_ arguments: [String: JSONValue], _ key: String) throws -> String {
    guard let value = arguments[key], !value.isNull else {
      throw AgentHostMCPArgumentError("missing required argument: \(key)")
    }
    guard let raw = value.stringValue else { throw AgentHostMCPArgumentError("\(key) must be a string") }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AgentHostMCPArgumentError("missing required argument: \(key)") }
    guard trimmed.utf8.count <= maximumValueBytes else {
      throw AgentHostMCPArgumentError("\(key) is too long (max \(maximumValueBytes) bytes)")
    }
    guard !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      throw AgentHostMCPArgumentError("\(key) must not contain control characters")
    }
    return trimmed
  }

  /// 必需的原样字符串（命令）：不 trim、不清洗，边界由 `AgentHostCommandFraming.validate` 负责。
  static func requiredRawString(_ arguments: [String: JSONValue], _ key: String) throws -> String {
    guard let value = arguments[key], !value.isNull else {
      throw AgentHostMCPArgumentError("missing required argument: \(key)")
    }
    guard let raw = value.stringValue else { throw AgentHostMCPArgumentError("\(key) must be a string") }
    return raw
  }

  /// 可选的说明性字符串：去控制字符、截断；空串视为缺失。它只用于展示，宽容处理。
  static func optionalString(_ arguments: [String: JSONValue], _ key: String, maximumBytes: Int) -> String? {
    guard let raw = arguments[key]?.stringValue else { return nil }
    let cleaned = sanitize(raw, maximumBytes: maximumBytes)
    return cleaned.isEmpty ? nil : cleaned
  }

  /// 可选整数：接受整数值或数字字符串（agent 偶尔写成 "30"）；越界或非整数报错，不静默夹值。
  static func integer(_ arguments: [String: JSONValue], _ key: String, range: ClosedRange<Int>) throws -> Int? {
    guard let value = arguments[key], !value.isNull else { return nil }
    let number: Int?
    switch value {
    case .number(let double): number = double.rounded() == double && abs(double) < 1e9 ? Int(double) : nil
    case .string(let text): number = Int(text.trimmingCharacters(in: .whitespaces))
    default: number = nil
    }
    guard let number else { throw AgentHostMCPArgumentError("\(key) must be an integer") }
    guard range.contains(number) else {
      throw AgentHostMCPArgumentError("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
    }
    return number
  }

  /// 剥离全部控制字符（含 DEL）、trim，再按 UTF-8 字节在字符边界截断。
  static func sanitize(_ raw: String, maximumBytes: Int) -> String {
    let filtered = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
    return AgentHostCommandFraming.prefix(
      filtered.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: maximumBytes)
  }
}
