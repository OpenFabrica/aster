// `aster pane close|split|list` 与 `aster tab new|close|focus|rename|list` 的参数解析，以及这两组的分组帮助。
// 从 AsterCLIArguments.swift 拆出来：那个文件已经接近长度上限，结构命令单独成组。

import Foundation

/// 有独立帮助文本的命令组。
public enum AsterCLIHelpTopic: String, Equatable, Sendable {
  case pane, tab
}

extension AsterCLIArguments {
  // MARK: 分组帮助

  /// `pane` 组的用法；总帮助与 `aster pane -h` 共用这一份。
  public static let paneUsage = """
    Pane（<pane> 是 Pane 短 ID，如 w1:p5；省略时用 $ASTER_PANE_ID）:
      pane list [--tab <tab>|--current]
      pane read [<pane>|--pane <id>|--current] [--source visible|recent] [--lines N]
      pane send-text [<pane>|--pane <id>|--current] <text> [--enter]
      pane send-keys [--pane <id>|--current] <key>...
      pane focus [<pane>|--pane <id>|--current]
      pane wait-output [<pane>|--pane <id>|--current] (--match <text>|--regex <re>) [--source ...] [--lines N] [--timeout ms]
      pane split [<pane>|--pane <id>|--current] [--direction right|left|down|up]
      pane close <pane>|--pane <id>|--current
    """

  /// `tab` 组的用法；总帮助与 `aster tab -h` 共用这一份。
  public static let tabUsage = """
    标签（<tab> 是标签短 ID，或标签里任意 Pane 的 ID）:
      tab list [--window <id>|--current]
      tab new [--cwd <dir>] [--window <id>]
      tab close <tab>|--current
      tab focus <tab>|--current
      tab rename <tab>|--current (<title>|--clear)
    """

  /// `aster pane -h` / `aster tab -h` 打印的文本：该组用法 + 通用选项说明。
  public static func usage(for topic: AsterCLIHelpTopic) -> String {
    let body: String
    let notes: String
    switch topic {
    case .pane:
      body = paneUsage
      notes = """
        list 列出全部 Pane（* 为所在标签的焦点 Pane）；--tab 只列某个标签，--current 只列调用者所在标签。
        split / close 需在 Aster 终端内运行（ASTER_ENV=1），并开启「IPC 允许发送按键」。
        旧命令 pane run | exec | capture 继续可用。
        """
    case .tab:
      body = tabUsage
      notes = """
        list 列出全部标签（* 为窗口的当前标签，WINDOW 列的 * 为焦点窗口）；--window 只列某个窗口，
        --current 只列调用者所在窗口。--window 也接受窗口里任意标签或 Pane 的 ID。
        new / close 需在 Aster 终端内运行（ASTER_ENV=1），并开启「IPC 允许发送按键」。
        tab badge --kind <kind> | --clear 给当前终端标签加徽标。
        """
    }
    return """
      用法: aster [--json|--format text|json] \(topic.rawValue) <子命令> [参数]

      \(body)

      \(notes)
      """
  }

  /// 判断 `pane` / `tab` 的参数是不是在要分组帮助：只写组名、首个参数是 `-h` / `--help` / `help`，
  /// 或新语法子命令后（`--` 之前）带 `-h` / `--help`。旧语法子命令（`pane run`、`tab badge` 等）
  /// 自己处理参数，不在这里拦截，免得改掉它们原有的行为。
  static func helpTopic(group: String, arguments: [String]) -> AsterCLIHelpTopic? {
    guard let topic = AsterCLIHelpTopic(rawValue: group) else { return nil }
    let helpFlags: Set<String> = ["-h", "--help"]
    guard let first = arguments.first else { return topic }
    if helpFlags.contains(first) || first == "help" { return topic }
    let newSyntax: Set<String> =
      topic == .pane
      ? ["list", "read", "send-text", "send-keys", "focus", "wait-output", "split", "close"] : tabSubcommands
    guard newSyntax.contains(first) else { return nil }
    return arguments.dropFirst().prefix { $0 != "--" }.contains(where: helpFlags.contains) ? topic : nil
  }

  // MARK: pane

  /// `pane close | split | list`：结构类 pane 子命令。
  static func parseLayoutPane(_ arguments: [String], subcommand: String) throws -> AsterCLICommand {
    switch subcommand {
    case "list":
      let parsed = try parseOptions(arguments, command: "pane list", flags: ["--current"], valued: ["--tab"])
      guard parsed.positionals.isEmpty else {
        throw AsterCLIArgumentError("pane list 不接受位置参数（标签用 --tab）")
      }
      return .paneList(tab: try listScope(parsed, option: "--tab", command: "pane list"))
    case "close":
      let parsed = try parseOptions(
        arguments, command: "pane close", flags: ["--current"], valued: ["--pane"])
      // 关闭会结束 Pane 里的进程：不接受「没写目标就关调用者自己」的缺省行为。
      guard let pane = try paneSelector(parsed, allowPositional: true, command: "pane close") else {
        throw AsterCLIArgumentError("pane close 需要 <pane>、--pane <id> 或 --current")
      }
      return .paneClose(PaneCloseParams(pane: pane))
    case "split":
      let parsed = try parseOptions(
        arguments, command: "pane split", flags: ["--current"], valued: ["--pane", "--direction"])
      var direction = SplitDirection.right
      if let raw = parsed.values["--direction"] {
        guard let value = SplitDirection(rawValue: raw) else {
          throw AsterCLIArgumentError("--direction 只支持 right | left | down | up")
        }
        direction = value
      }
      return .paneSplit(
        pane: try paneSelector(parsed, allowPositional: true, command: "pane split"),
        direction: direction)
    default:
      throw AsterCLIArgumentError("未知子命令: pane \(subcommand)")
    }
  }

  // MARK: tab

  /// `tab new | close | focus | rename | list`。close / focus / rename 必须显式指定标签（或 `--current`）。
  /// `<tab>` 接受标签短 ID，也接受标签里任意 Pane 的 selector。
  static func parseTab(_ input: [String]) throws -> AsterCLICommand {
    guard let subcommand = input.first else {
      throw AsterCLIArgumentError("tab 需要子命令：list | new | close | focus | rename")
    }
    let arguments = Array(input.dropFirst())
    let command = "tab \(subcommand)"
    switch subcommand {
    case "list":
      let parsed = try parseOptions(arguments, command: command, flags: ["--current"], valued: ["--window"])
      guard parsed.positionals.isEmpty else {
        throw AsterCLIArgumentError("tab list 不接受位置参数（窗口用 --window）")
      }
      return .tabList(window: try listScope(parsed, option: "--window", command: command))
    case "new":
      let parsed = try parseOptions(arguments, command: command, flags: [], valued: ["--cwd", "--window"])
      guard parsed.positionals.isEmpty else {
        throw AsterCLIArgumentError("tab new 不接受位置参数（目录用 --cwd）")
      }
      if let cwd = parsed.values["--cwd"], cwd.isEmpty {
        throw AsterCLIArgumentError("--cwd 不能为空")
      }
      let params = TabNewParams(window: parsed.values["--window"], cwd: nil)
      try mapValidation { try params.validate() }
      return .tabNew(window: params.window, cwd: parsed.values["--cwd"])
    case "close", "focus":
      let parsed = try parseOptions(arguments, command: command, flags: ["--current"], valued: [])
      guard parsed.positionals.count <= 1 else {
        throw AsterCLIArgumentError("\(command) 只接受一个 <tab>")
      }
      let params = TabTargetParams(tab: try requiredTarget(parsed, command: command))
      try mapValidation { try params.validate() }
      return subcommand == "close" ? .tabClose(params) : .tabFocus(params)
    case "rename":
      let parsed = try parseOptions(
        arguments, command: command, flags: ["--current", "--clear"], valued: [])
      // 位置参数是 `[<tab>] [<title>]`：给了 --current 就没有 <tab>，给了 --clear 就没有 <title>。
      var positionals = parsed.positionals
      let tab: String
      if parsed.flags.contains("--current") {
        tab = "current"
      } else {
        guard !positionals.isEmpty else {
          throw AsterCLIArgumentError("tab rename 需要 <tab> 或 --current")
        }
        tab = positionals.removeFirst()
      }
      let title: String?
      if parsed.flags.contains("--clear") {
        guard positionals.isEmpty else {
          throw AsterCLIArgumentError("tab rename 的 --clear 不能和 <title> 同时给出")
        }
        title = nil
      } else {
        guard positionals.count == 1, !positionals[0].isEmpty else {
          throw AsterCLIArgumentError("tab rename 需要一个 <title>（带空格请加引号），或 --clear 恢复自动标题")
        }
        title = positionals[0]
      }
      let params = TabRenameParams(tab: tab, title: title)
      try mapValidation { try params.validate() }
      return .tabRename(params)
    default:
      throw AsterCLIArgumentError("未知子命令: tab \(subcommand)")
    }
  }

  /// list 的范围：`--current` 记作 `current`（运行时换成调用者的 Pane），`<option> <id>` 原样带回，都没有为 nil。
  private static func listScope(_ parsed: ParsedOptions, option: String, command: String) throws -> String? {
    let explicit = parsed.values[option]
    if parsed.flags.contains("--current") {
      guard explicit == nil else { throw AsterCLIArgumentError("--current 与 \(option) 不能同时给出") }
      return "current"
    }
    // 列表在客户端按快照筛选，快照里只有短 ID 与 agent 名，旧 `p_<UUID>` 形态无从匹配，直接拒绝。
    if let explicit {
      switch ControlTargetSelector(parsing: explicit) {
      case .window?, .tab?, .pane?, .current?, .agentName?: break
      case .legacyPaneUUID?, nil:
        throw AsterCLIArgumentError("\(option) 只接受短 ID（如 w1、w1:t2、w1:p3）、agent 名或 current")
      }
    }
    return explicit
  }
}
