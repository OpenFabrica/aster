// `aster host exec|wait|read|interrupt|close|open|terminals`：agent 远程执行的 CLI 前端。
// 与 `host list` 分开：这组命令要自己处理 `--` 之后的命令文本，不能经过 main.swift 里
// 全局摘取 `--json` 的路由（`host exec h -- grep --json` 的 `--json` 属于远端命令）。
import AsterCore
import Foundation

/// agent 远程执行子命令的解析、调用与输出。
enum HostExecCommands {
  /// 命令未结束（running / needs_input / interrupted / ended）时的退出码：EX_TEMPFAIL，
  /// 让脚本与 agent 区分「远端命令失败」与「还没结果，稍后 host wait」。
  static let pendingExitCode: Int32 = 75

  static let subcommands: Set<String> = ["exec", "wait", "read", "interrupt", "close", "open", "terminals"]

  /// 一次解析结果：控制方法、params、客户端超时与输出方式。
  struct Invocation {
    var subcommand: String
    var method: AgentHostControlMethod
    var params: JSONValue
    var timeout: TimeInterval
    var wantsJSON: Bool
  }

  /// 判断 argv 是否属于本模块（`host` + 本组子命令）。
  static func matches(_ argv: [String]) -> Bool {
    argv.count >= 2 && argv[0] == "host" && subcommands.contains(argv[1])
  }

  /// 解析、调用并按约定退出；错误输出与 main.swift 的路由保持一致。
  static func run(_ argv: [String], explicitSocket: String?, environment: [String: String]) -> Never {
    do {
      let invocation = try parse(argv, environment: environment)
      let client = ControlClient(
        socketPath: try ControlClient.resolveSocketPath(explicit: explicitSocket, environment: environment),
        environment: environment)
      let result = try client.call(
        invocation.method.rawValue, params: invocation.params, timeout: invocation.timeout)
      exit(try output(result, for: invocation))
    } catch let error as AsterControlError {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let payload = (try? encoder.encode(error)).map { String(decoding: $0, as: UTF8.self) }
        ?? "{\"code\":\"\(error.code.rawValue)\",\"message\":\"\(error.message)\"}"
      writeStandardError(payload + "\n")
      exit(AsterCLIExitCode.serverError)
    } catch let error as ControlClientError {
      writeStandardError(error.message + "\n")
      exit(error.exitCode)
    } catch {
      writeStandardError("aster: \(error)\n")
      exit(AsterCLIExitCode.serverError)
    }
  }

  // MARK: - 解析

  /// 解析 `host <子命令> …`。只有 `exec` 识别 `--`，其后的词原样作为命令文本。
  static func parse(_ argv: [String], environment: [String: String]) throws -> Invocation {
    let subcommand = argv[1]
    var arguments = Array(argv.dropFirst(2))
    var commandWords: [String]?
    if subcommand == "exec", let separator = arguments.firstIndex(of: "--") {
      commandWords = Array(arguments[arguments.index(after: separator)...])
      arguments = Array(arguments[..<separator])
    }
    var options = try OptionScanner(arguments)
    let caller = AgentHostCaller(
      session: try options.value("--session") ?? defaultSession(environment),
      client: clientName(environment), callerPane: nonEmpty(environment["ASTER_PANE_ID"]))
    let wantsJSON = options.flag("--json")

    let invocation: Invocation
    switch subcommand {
    case "exec":
      let host = try options.singlePositional("host exec 需要 <host>")
      guard let commandWords, !commandWords.isEmpty else { throw usageError("host exec 需要 -- <command…>") }
      let timeoutMs = try options.seconds("--timeout")
      let params = HostExecParams(
        host: host, command: commandWords.joined(separator: " "), agent: caller,
        reason: try options.value("--reason"), timeoutMs: timeoutMs,
        maxOutputBytes: try options.integer("--max-output"))
      invocation = Invocation(
        subcommand: subcommand, method: .hostExec, params: try encode(params),
        timeout: waitingTimeout(timeoutMs), wantsJSON: wantsJSON)
    case "wait":
      let timeoutMs = try options.seconds("--timeout")
      let params = HostWaitParams(
        commandID: try options.singlePositional("host wait 需要 <command_id>"), agent: caller, timeoutMs: timeoutMs)
      invocation = Invocation(
        subcommand: subcommand, method: .hostWait, params: try encode(params),
        timeout: waitingTimeout(timeoutMs), wantsJSON: wantsJSON)
    case "read":
      let params = HostReadParams(
        host: try options.singlePositional("host read 需要 <host>"), agent: caller,
        lines: try options.integer("--lines"))
      invocation = Invocation(
        subcommand: subcommand, method: .hostRead, params: try encode(params),
        timeout: ControlClient.defaultTimeout, wantsJSON: wantsJSON)
    case "interrupt":
      // command id 由服务端生成，格式固定为 `c-<12 位小写十六进制>`；其余一律按主机解析。
      let target = try options.singlePositional("host interrupt 需要 <host|command_id>")
      let params = isCommandID(target)
        ? HostInterruptParams(commandID: target, agent: caller)
        : HostInterruptParams(host: target, agent: caller)
      invocation = Invocation(
        subcommand: subcommand, method: .hostInterrupt, params: try encode(params),
        timeout: ControlClient.defaultTimeout, wantsJSON: wantsJSON)
    case "close":
      let params = HostCloseParams(host: try options.singlePositional("host close 需要 <host>"), agent: caller)
      invocation = Invocation(
        subcommand: subcommand, method: .hostClose, params: try encode(params),
        timeout: ControlClient.defaultTimeout, wantsJSON: wantsJSON)
    case "open":
      let timeoutMs = try options.seconds("--timeout")
      let params = HostOpenParams(
        host: try options.singlePositional("host open 需要 <host>"), agent: caller, timeoutMs: timeoutMs)
      invocation = Invocation(
        subcommand: subcommand, method: .hostOpen, params: try encode(params),
        timeout: waitingTimeout(timeoutMs), wantsJSON: wantsJSON)
    default:
      // terminals：列出全部 agent 终端（不按会话过滤），所以不带 agent。
      try options.expectNoPositionals("host terminals 不接受位置参数")
      invocation = Invocation(
        subcommand: subcommand, method: .hostTerminals, params: try encode(HostTerminalsParams()),
        timeout: ControlClient.defaultTimeout, wantsJSON: wantsJSON)
    }
    try options.expectConsumed()
    return invocation
  }

  /// 会话键：`--session` > `$ASTER_AGENT_SESSION` > `pane:$ASTER_PANE_ID` > `cli:default`。
  static func defaultSession(_ environment: [String: String]) -> String {
    if let session = nonEmpty(environment["ASTER_AGENT_SESSION"]) { return session }
    if let pane = nonEmpty(environment["ASTER_PANE_ID"]) { return "pane:\(pane)" }
    return "cli:default"
  }

  /// 审计用客户端名：按 agent 注入的环境变量识别 Claude Code 与 Codex。
  static func clientName(_ environment: [String: String]) -> String {
    if environment["CLAUDECODE"] == "1" { return "claude-code" }
    if environment.keys.contains(where: { $0.hasPrefix("CODEX_") }) { return "codex" }
    return "cli"
  }

  /// `c-` 加 12 位小写十六进制。
  static func isCommandID(_ value: String) -> Bool {
    guard value.hasPrefix("c-") else { return false }
    let digits = value.dropFirst(2)
    return digits.count == 12 && digits.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  /// 等待类请求的客户端超时：服务端等待时长 + 15 s 余量。
  static func waitingTimeout(_ timeoutMs: Int?) -> TimeInterval {
    TimeInterval(AgentHostValidation.clampedTimeout(timeoutMs)) / 1_000 + 15
  }

  /// 本地校验后编码：参数错误按用法错误（退出码 2）报告，不必连 App。
  private static func encode<T: Encodable & AsterControlValidatable>(_ params: T) throws -> JSONValue {
    do {
      try params.validate()
    } catch let error as AsterControlError {
      throw usageError(error.message)
    }
    return try JSONValue(encoding: params)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// 用法错误，附完整的 host 命令用法。
  static func usageError(_ message: String) -> ControlClientError {
    ControlClientError(message: "aster: \(message)\n\n\(HostCommands.usage)", exitCode: AsterCLIExitCode.usage)
  }
}

// MARK: - 输出

extension HostExecCommands {
  /// 打印结果并返回进程退出码。结果形状不认识时退回漂亮 JSON，不丢信息。
  static func output(_ result: JSONValue, for invocation: Invocation) throws -> Int32 {
    switch invocation.method {
    case .hostExec, .hostWait:
      guard let exec = try? result.decoded(as: HostExecResult.self) else {
        printLine(try prettyJSON(result))
        return AsterCLIExitCode.success
      }
      return try outputExecResult(exec, raw: result, wantsJSON: invocation.wantsJSON)
    case _ where invocation.wantsJSON:
      printLine(try prettyJSON(result))
    case .hostInterrupt:
      if let exec = try? result.decoded(as: HostExecResult.self) {
        printLine("\(exec.status.rawValue)\t\(exec.commandID)")
      } else {
        printLine(try prettyJSON(result))
      }
    case .hostRead:
      if let read = try? result.decoded(as: HostReadResult.self) {
        printLine(read.text)
      } else {
        printLine(try prettyJSON(result))
      }
    case .hostClose:
      printLine("closed")
    case .hostOpen:
      if let terminal = try? result.decoded(as: HostTerminalInfo.self) {
        printLine(terminalLine(terminal))
      } else {
        printLine(try prettyJSON(result))
      }
    case .hostTerminals:
      if let list = try? result.decoded(as: HostTerminalsResult.self) {
        if !list.terminals.isEmpty { printLine(list.terminals.map(terminalLine).joined(separator: "\n")) }
      } else {
        printLine(try prettyJSON(result))
      }
    }
    return AsterCLIExitCode.success
  }

  /// exec / wait 的输出约定。
  ///
  /// 文本模式：输出写 stdout，完成时以远端退出码退出；未完成时 stdout 仍写已有输出，
  /// stderr 写一行 `{"status","command_id","prompt"}` 并以 75 退出，调用方据此 `host wait`。
  /// 远端退出码超出 0-255 时：大于 255 夹到 255；负数（标记符解析失败）也报 255，避免误报成功。
  private static func outputExecResult(_ result: HostExecResult, raw: JSONValue, wantsJSON: Bool) throws -> Int32 {
    let completed = result.status == .completed
    if wantsJSON {
      printLine(try prettyJSON(raw))
      return completed ? AsterCLIExitCode.success : pendingExitCode
    }
    if !result.output.isEmpty {
      FileHandle.standardOutput.write(Data((result.output.hasSuffix("\n") ? result.output : result.output + "\n").utf8))
    }
    if result.outputTruncated {
      writeStandardError("aster: output truncated (raise --max-output to see more)\n")
    }
    if completed {
      let code = result.exitCode ?? 0
      return Int32(code < 0 ? 255 : min(code, 255))
    }
    var pending: [String: JSONValue] = [
      "status": .string(result.status.rawValue), "command_id": .string(result.commandID),
    ]
    pending["prompt"] = result.prompt.map(JSONValue.string) ?? .null
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    writeStandardError(String(decoding: try encoder.encode(JSONValue.object(pending)), as: UTF8.self) + "\n")
    return pendingExitCode
  }

  /// 终端一行：id、主机名、目标、状态、会话、运行中的命令（无则 `-`），制表符分隔。
  private static func terminalLine(_ terminal: HostTerminalInfo) -> String {
    [
      terminal.terminalID, terminal.hostName, terminal.target, terminal.state.rawValue, terminal.session,
      terminal.runningCommandID ?? "-",
    ].joined(separator: "\t")
  }
}

// MARK: - 选项扫描

/// 极简选项扫描：`--name value` / `--name=value` / 布尔开关 / 位置参数。
///
/// 先按全集切词，再由各子命令「领取」自己支持的选项；最后 `expectConsumed` 拒绝
/// 给错子命令的选项（如 `host read h --reason x`），不静默忽略。
struct OptionScanner {
  private static let valueOptions: Set<String> = ["--session", "--reason", "--timeout", "--max-output", "--lines"]
  private static let flagOptions: Set<String> = ["--json"]

  private var values: [String: String] = [:]
  private var flags: Set<String> = []
  private var positionals: [String] = []
  private var consumed: Set<String> = []

  /// 切词；未知选项、缺值与重复选项立即报错。
  init(_ arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      guard argument.hasPrefix("--") else {
        positionals.append(argument)
        continue
      }
      var name = argument
      var inlineValue: String?
      if let equals = argument.firstIndex(of: "=") {
        name = String(argument[..<equals])
        inlineValue = String(argument[argument.index(after: equals)...])
      }
      if Self.flagOptions.contains(name), inlineValue == nil {
        flags.insert(name)
      } else if Self.valueOptions.contains(name) {
        guard values[name] == nil else { throw HostExecCommands.usageError("\(name) 重复") }
        if let inlineValue {
          values[name] = inlineValue
        } else {
          guard index < arguments.count else { throw HostExecCommands.usageError("\(name) 需要取值") }
          values[name] = arguments[index]
          index += 1
        }
      } else {
        throw HostExecCommands.usageError("未知选项: \(argument)")
      }
    }
  }

  /// 领取一个取值选项。
  mutating func value(_ name: String) throws -> String? {
    consumed.insert(name)
    return values[name]
  }

  /// 领取一个布尔开关。
  mutating func flag(_ name: String) -> Bool {
    consumed.insert(name)
    return flags.contains(name)
  }

  /// 领取一个整数选项。
  mutating func integer(_ name: String) throws -> Int? {
    guard let raw = try value(name) else { return nil }
    guard let number = Int(raw) else { throw HostExecCommands.usageError("\(name) 需要整数，收到 \(raw)") }
    return number
  }

  /// 领取一个秒数选项（可带小数），换算成毫秒。
  mutating func seconds(_ name: String) throws -> Int? {
    guard let raw = try value(name) else { return nil }
    guard let seconds = Double(raw), seconds.isFinite, seconds >= 0, seconds <= 86_400 else {
      throw HostExecCommands.usageError("\(name) 需要非负秒数，收到 \(raw)")
    }
    return Int((seconds * 1_000).rounded())
  }

  /// 恰好一个位置参数。
  func singlePositional(_ missingMessage: String) throws -> String {
    guard let first = positionals.first else { throw HostExecCommands.usageError(missingMessage) }
    guard positionals.count == 1 else {
      throw HostExecCommands.usageError("多余的参数: \(positionals.dropFirst().joined(separator: " "))")
    }
    return first
  }

  /// 不允许位置参数。
  func expectNoPositionals(_ message: String) throws {
    guard positionals.isEmpty else { throw HostExecCommands.usageError(message) }
  }

  /// 出现过但本子命令没领取的选项一律报错。
  func expectConsumed() throws {
    let given = Set(values.keys).union(flags)
    if let stray = given.subtracting(consumed).sorted().first {
      throw HostExecCommands.usageError("此子命令不支持 \(stray)")
    }
  }
}
