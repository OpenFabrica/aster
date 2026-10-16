// `host.*` agent 远程执行的控制协议线格式：方法名、参数、结果与上限。
// 服务端（Sources/Aster/AgentHosts、Control/AgentHostControlCommands）、CLI 与 MCP 共用；
// 键名 snake_case，与 AsterControlProtocol 其余方法一致。
import Foundation

/// agent 远程执行的方法集。`host.list` 仍归 `HostControlMethod`（只读），这里只放会动终端的方法。
public enum AgentHostControlMethod: String, CaseIterable, Sendable {
  case hostOpen = "host.open"
  case hostExec = "host.exec"
  case hostWait = "host.wait"
  case hostRead = "host.read"
  case hostInterrupt = "host.interrupt"
  case hostClose = "host.close"
  case hostTerminals = "host.terminals"
}

/// 线格式上限与默认值。改动任何一项都要同步 docs/developer/agent-host-access.md。
public enum AgentHostLimits {
  /// 单条命令总字节数上限。
  public static let maximumCommandBytes = 16 * 1_024
  /// 命令里单行字节数上限：远端若是无行编辑的 sh，规范模式行缓冲只有 4 KiB。
  public static let maximumCommandLineBytes = 4_000
  public static let maximumReasonBytes = 512
  public static let maximumSessionBytes = 128
  public static let maximumClientBytes = 64
  public static let maximumHostBytes = 256
  public static let defaultTimeoutMilliseconds = 120_000
  public static let maximumTimeoutMilliseconds = 600_000
  public static let defaultMaximumOutputBytes = 64 * 1_024
  public static let maximumOutputBytesLimit = 1 * 1_024 * 1_024
  /// 截断时保留的开头字节数；其余预算给结尾。
  public static let truncationHeadBytes = 8 * 1_024
  public static let maximumReadLines = 500
  public static let defaultReadLines = 100
}

/// 调用方身份。`session` 是授权与终端复用的键；`client` 只进审计；`caller_pane` 来自
/// `$ASTER_PANE_ID`，服务端据此把 provider 与 agent session ID 并入有效会话键。
public struct AgentHostCaller: Codable, Equatable, Sendable, AsterControlValidatable {
  public var session: String
  public var client: String?
  public var callerPane: String?

  private enum CodingKeys: String, CodingKey {
    case session, client
    case callerPane = "caller_pane"
  }

  public init(session: String, client: String? = nil, callerPane: String? = nil) {
    self.session = session
    self.client = client
    self.callerPane = callerPane
  }

  /// 字节上限 + 禁止控制字符：这些值会进审计与面板标题。
  public func validate() throws {
    guard !session.isEmpty, session.utf8.count <= AgentHostLimits.maximumSessionBytes else {
      throw AsterControlError.invalidParams("agent.session 需为 1-\(AgentHostLimits.maximumSessionBytes) 字节")
    }
    try AgentHostValidation.rejectControlCharacters(session, field: "agent.session")
    if let client {
      guard client.utf8.count <= AgentHostLimits.maximumClientBytes else {
        throw AsterControlError.invalidParams("agent.client 最多 \(AgentHostLimits.maximumClientBytes) 字节")
      }
      try AgentHostValidation.rejectControlCharacters(client, field: "agent.client")
    }
    if let callerPane {
      guard callerPane.utf8.count <= ControlSelectorValidation.maximumSelectorBytes else {
        throw AsterControlError.invalidParams("agent.caller_pane 过长")
      }
      try AgentHostValidation.rejectControlCharacters(callerPane, field: "agent.caller_pane")
    }
  }
}

// MARK: - 参数

/// `host.open`：只建立（或复用）终端并等它就绪，不执行命令。
public struct HostOpenParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var host: String
  public var agent: AgentHostCaller
  public var timeoutMs: Int?

  private enum CodingKeys: String, CodingKey {
    case host, agent
    case timeoutMs = "timeout_ms"
  }

  public init(host: String, agent: AgentHostCaller, timeoutMs: Int? = nil) {
    self.host = host
    self.agent = agent
    self.timeoutMs = timeoutMs
  }

  public func validate() throws {
    try AgentHostValidation.validateHost(host)
    try agent.validate()
    try ControlSelectorValidation.validateTimeout(timeoutMs)
  }
}

/// `host.exec`：在主机的 agent 终端里执行一条命令。
public struct HostExecParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var host: String
  public var command: String
  public var agent: AgentHostCaller
  public var reason: String?
  public var timeoutMs: Int?
  public var maxOutputBytes: Int?

  private enum CodingKeys: String, CodingKey {
    case host, command, agent, reason
    case timeoutMs = "timeout_ms"
    case maxOutputBytes = "max_output_bytes"
  }

  public init(
    host: String, command: String, agent: AgentHostCaller, reason: String? = nil,
    timeoutMs: Int? = nil, maxOutputBytes: Int? = nil
  ) {
    self.host = host
    self.command = command
    self.agent = agent
    self.reason = reason
    self.timeoutMs = timeoutMs
    self.maxOutputBytes = maxOutputBytes
  }

  public func validate() throws {
    try AgentHostValidation.validateHost(host)
    try agent.validate()
    try AgentHostCommandFraming.validate(command: command)
    if let reason {
      guard reason.utf8.count <= AgentHostLimits.maximumReasonBytes else {
        throw AsterControlError.invalidParams("reason 最多 \(AgentHostLimits.maximumReasonBytes) 字节")
      }
      try AgentHostValidation.rejectControlCharacters(reason, field: "reason", allowNewline: true)
    }
    try ControlSelectorValidation.validateTimeout(timeoutMs)
    try AgentHostValidation.validateMaximumOutput(maxOutputBytes)
  }
}

/// `host.wait`：继续等待一条仍在运行（或等输入）的命令。只有发起会话能等。
public struct HostWaitParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var commandID: String
  public var agent: AgentHostCaller
  public var timeoutMs: Int?
  public var maxOutputBytes: Int?

  private enum CodingKeys: String, CodingKey {
    case agent
    case commandID = "command_id"
    case timeoutMs = "timeout_ms"
    case maxOutputBytes = "max_output_bytes"
  }

  public init(commandID: String, agent: AgentHostCaller, timeoutMs: Int? = nil, maxOutputBytes: Int? = nil) {
    self.commandID = commandID
    self.agent = agent
    self.timeoutMs = timeoutMs
    self.maxOutputBytes = maxOutputBytes
  }

  public func validate() throws {
    try AgentHostValidation.validateIdentifier(commandID, field: "command_id")
    try agent.validate()
    try ControlSelectorValidation.validateTimeout(timeoutMs)
    try AgentHostValidation.validateMaximumOutput(maxOutputBytes)
  }
}

/// `host.read`：读 agent 终端活动屏幕。`host` 与 `terminal_id` 二选一。
public struct HostReadParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var host: String?
  public var terminalID: String?
  public var agent: AgentHostCaller
  public var lines: Int?

  private enum CodingKeys: String, CodingKey {
    case host, agent, lines
    case terminalID = "terminal_id"
  }

  public init(host: String? = nil, terminalID: String? = nil, agent: AgentHostCaller, lines: Int? = nil) {
    self.host = host
    self.terminalID = terminalID
    self.agent = agent
    self.lines = lines
  }

  public func validate() throws {
    try AgentHostValidation.validateExactlyOne(host: host, other: terminalID, otherField: "terminal_id")
    try agent.validate()
    if let lines, !(1...AgentHostLimits.maximumReadLines).contains(lines) {
      throw AsterControlError.invalidParams("lines 需在 1-\(AgentHostLimits.maximumReadLines)")
    }
  }
}

/// `host.interrupt`：向正在运行的命令发 Ctrl-C。`command_id` 与 `host` 二选一。
public struct HostInterruptParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var commandID: String?
  public var host: String?
  public var agent: AgentHostCaller

  private enum CodingKeys: String, CodingKey {
    case host, agent
    case commandID = "command_id"
  }

  public init(commandID: String? = nil, host: String? = nil, agent: AgentHostCaller) {
    self.commandID = commandID
    self.host = host
    self.agent = agent
  }

  public func validate() throws {
    try AgentHostValidation.validateExactlyOne(host: host, other: commandID, otherField: "command_id")
    try agent.validate()
  }
}

/// `host.close`：关闭本会话在该主机上的 agent 终端。`host` 与 `terminal_id` 二选一。
public struct HostCloseParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var host: String?
  public var terminalID: String?
  public var agent: AgentHostCaller

  private enum CodingKeys: String, CodingKey {
    case host, agent
    case terminalID = "terminal_id"
  }

  public init(host: String? = nil, terminalID: String? = nil, agent: AgentHostCaller) {
    self.host = host
    self.terminalID = terminalID
    self.agent = agent
  }

  public func validate() throws {
    try AgentHostValidation.validateExactlyOne(host: host, other: terminalID, otherField: "terminal_id")
    try agent.validate()
  }
}

/// `host.terminals`：列出 agent 终端；带 `agent` 时只列本会话的。
public struct HostTerminalsParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var agent: AgentHostCaller?

  public init(agent: AgentHostCaller? = nil) { self.agent = agent }

  public func validate() throws { try agent?.validate() }
}

// MARK: - 结果

/// 一次执行的结局。`running` / `needs_input` 不是错误：命令仍在终端里，调 `host.wait` 继续。
public enum HostExecStatus: String, Codable, CaseIterable, Sendable {
  case completed
  case running
  case needsInput = "needs_input"
  case interrupted
  case ended
}

/// `host.exec` / `host.wait` / `host.interrupt` 的结果。
public struct HostExecResult: Codable, Equatable, Sendable {
  public var commandID: String
  public var terminalID: String
  public var hostID: String
  public var hostName: String
  public var status: HostExecStatus
  /// 只有 `completed` 才有退出码。
  public var exitCode: Int?
  public var output: String
  public var outputTruncated: Bool
  /// `needs_input` 时屏幕最后一行（如 `[sudo] password for deploy:`）。
  public var prompt: String?
  public var durationMs: Int

  private enum CodingKeys: String, CodingKey {
    case status, output, prompt
    case commandID = "command_id"
    case terminalID = "terminal_id"
    case hostID = "host_id"
    case hostName = "host_name"
    case exitCode = "exit_code"
    case outputTruncated = "output_truncated"
    case durationMs = "duration_ms"
  }

  public init(
    commandID: String, terminalID: String, hostID: String, hostName: String, status: HostExecStatus,
    exitCode: Int? = nil, output: String = "", outputTruncated: Bool = false, prompt: String? = nil,
    durationMs: Int = 0
  ) {
    self.commandID = commandID
    self.terminalID = terminalID
    self.hostID = hostID
    self.hostName = hostName
    self.status = status
    self.exitCode = exitCode
    self.output = output
    self.outputTruncated = outputTruncated
    self.prompt = prompt
    self.durationMs = durationMs
  }
}

/// agent 终端的生命周期状态。
public enum HostTerminalState: String, Codable, CaseIterable, Sendable {
  case connecting
  case ready
  case busy
  case needsInput = "needs_input"
  case ended
}

/// 一个 agent 终端的投影。`session` 是有效会话键（已并入 provider 与 agent session ID）。
public struct HostTerminalInfo: Codable, Equatable, Sendable {
  public var terminalID: String
  public var hostID: String
  public var hostName: String
  public var target: String
  public var session: String
  public var state: HostTerminalState
  public var runningCommandID: String?

  private enum CodingKeys: String, CodingKey {
    case target, session, state
    case terminalID = "terminal_id"
    case hostID = "host_id"
    case hostName = "host_name"
    case runningCommandID = "running_command_id"
  }

  public init(
    terminalID: String, hostID: String, hostName: String, target: String, session: String,
    state: HostTerminalState, runningCommandID: String? = nil
  ) {
    self.terminalID = terminalID
    self.hostID = hostID
    self.hostName = hostName
    self.target = target
    self.session = session
    self.state = state
    self.runningCommandID = runningCommandID
  }
}

public struct HostTerminalsResult: Codable, Equatable, Sendable {
  public var terminals: [HostTerminalInfo]

  public init(terminals: [HostTerminalInfo]) { self.terminals = terminals }
}

public struct HostReadResult: Codable, Equatable, Sendable {
  public var terminalID: String
  public var text: String

  private enum CodingKeys: String, CodingKey {
    case text
    case terminalID = "terminal_id"
  }

  public init(terminalID: String, text: String) {
    self.terminalID = terminalID
    self.text = text
  }
}

// MARK: - 校验

/// `host.*` 参数的共用校验。
public enum AgentHostValidation {
  /// 主机：UUID 或精确名称；非空、有界、无控制字符。
  static func validateHost(_ host: String) throws {
    guard !host.isEmpty, host.utf8.count <= AgentHostLimits.maximumHostBytes else {
      throw AsterControlError.invalidParams("host 需为 1-\(AgentHostLimits.maximumHostBytes) 字节")
    }
    try rejectControlCharacters(host, field: "host")
  }

  /// command_id / terminal_id：服务端生成的短标识，只允许字母数字与 `-`。
  static func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 64,
      value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    else {
      throw AsterControlError.invalidParams("\(field) 不合法")
    }
  }

  /// `host` 与另一个字段必须恰好给一个。
  static func validateExactlyOne(host: String?, other: String?, otherField: String) throws {
    switch (host, other) {
    case (let host?, nil): try validateHost(host)
    case (nil, let value?): try validateIdentifier(value, field: otherField)
    default: throw AsterControlError.invalidParams("host 与 \(otherField) 需恰好给一个")
    }
  }

  static func validateMaximumOutput(_ value: Int?) throws {
    guard let value else { return }
    guard (1...AgentHostLimits.maximumOutputBytesLimit).contains(value) else {
      throw AsterControlError.invalidParams("max_output_bytes 需在 1-\(AgentHostLimits.maximumOutputBytesLimit)")
    }
  }

  /// 拒绝 C0 控制字符与 DEL；`allowNewline` 时放行 `\n` 与 `\t`。
  static func rejectControlCharacters(_ text: String, field: String, allowNewline: Bool = false) throws {
    for scalar in text.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
      if allowNewline, scalar == "\n" || scalar == "\t" { continue }
      throw AsterControlError.invalidParams("\(field) 含控制字符")
    }
  }

  /// 把 `timeout_ms` 归一到 [0, 上限]；nil 用默认值。
  public static func clampedTimeout(_ milliseconds: Int?) -> Int {
    min(max(milliseconds ?? AgentHostLimits.defaultTimeoutMilliseconds, 0), AgentHostLimits.maximumTimeoutMilliseconds)
  }
}
