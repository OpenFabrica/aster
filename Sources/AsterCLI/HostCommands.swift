import AsterCore
import Foundation

/// `aster host list` 的 CLI 前端：只读列出 App 里保存的 SSH 主机。
///
/// 与 `MachineCommands` 一样在 `AsterCLIArguments.parse` 之前拦截，复用它的
/// `Invocation` 与输出格式开关，文本输出同样是制表符分隔的一行一条。
/// 输出里没有任何秘密，也不说明「是否保存了口令」。
enum HostCommands {
  static let usage = """
    已保存主机：
      host list [--tag <标签>]... [--json]

    agent 远程执行（在已保存主机上的持久 Shell 里执行；首次访问需用户在 Aster 里批准）：
      host exec <host> [--session K] [--reason R] [--timeout S] [--max-output N] [--json] -- <command…>
      host wait <command_id> [--timeout S] [--json]
      host read <host> [--lines N]
      host interrupt <host|command_id>
      host close <host>
      host open <host> [--timeout S]
      host terminals [--json]
      `--` 之后的词以单个空格拼接；引号与转义由调用方的 Shell 处理，单个词原样传递。
      会话键：--session > $ASTER_AGENT_SESSION > pane:$ASTER_PANE_ID > cli:default。
      exec/wait 退出码：完成时为远端退出码；未完成（running/needs_input/…）为 75，
      stderr 输出一行 {"status","command_id","prompt"}，随后用 host wait 继续。
    """

  /// 判断这组 argv 是否属于本模块。返回 false 表示交回其它解析器。
  static func matches(_ argv: [String]) -> Bool {
    argv.first == "host"
  }

  /// 解析 argv（已摘掉 `--json` / `--format`）。失败抛 `ControlClientError.usage`。
  static func parse(_ argv: [String]) throws -> MachineCommands.Invocation {
    guard argv.count >= 2 else { throw usageError("host 需要子命令") }
    let subcommand = argv[1]
    let rest = argv.dropFirst(2)
    switch subcommand {
    case "list":
      let tags = try parseTagOptions(Array(rest))
      let params: JSONValue? = tags.isEmpty ? nil : .object(["tags": .array(tags.map { .string($0) })])
      return MachineCommands.Invocation(method: "host.list", params: params, render: renderHostList)
    default:
      throw usageError("未知子命令: host \(subcommand)")
    }
  }

  /// 解析 `host list` 的 `--tag X` / `--tag=X`（可重复）；其它参数都是用法错误。
  static func parseTagOptions(_ arguments: [String]) throws -> [String] {
    var tags: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--tag" {
        guard index + 1 < arguments.count else { throw usageError("--tag 需要一个标签") }
        tags.append(arguments[index + 1])
        index += 2
      } else if argument.hasPrefix("--tag=") {
        tags.append(String(argument.dropFirst("--tag=".count)))
        index += 1
      } else {
        throw usageError("host list 不接受参数：\(argument)")
      }
    }
    if tags.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      throw usageError("--tag 不能为空")
    }
    return tags
  }

  private static func usageError(_ message: String) -> ControlClientError {
    ControlClientError(message: "aster: \(message)\n\n\(usage)", exitCode: AsterCLIExitCode.usage)
  }

  // MARK: - 文本渲染

  /// 主机列表：每行「id 名称 分组 user@host:port 跳板 标签」，标签用逗号连接，缺省字段写 `-`。
  static func renderHostList(_ value: JSONValue) throws -> String {
    var lines: [String] = []
    if case .string(let error)? = value["configurationError"] {
      lines.append("! 配置错误：\(error)")
    }
    guard case .array(let hosts)? = value["hosts"] else { return lines.joined(separator: "\n") }
    for host in hosts {
      lines.append(
        [
          text(host["id"]), text(host["name"]), text(host["group"], fallback: "-"),
          text(host["target"]),
          text(host["jumpHostName"], fallback: text(host["jumpHostID"], fallback: "-")),
          tagText(host["tags"]),
        ].joined(separator: "\t"))
    }
    return lines.joined(separator: "\n")
  }

  /// 标签数组连成逗号分隔文本；没有标签时写 `-`。
  private static func tagText(_ value: JSONValue?) -> String {
    guard case .array(let tags)? = value else { return "-" }
    let names = tags.compactMap { tag -> String? in
      if case .string(let name) = tag { return name }
      return nil
    }
    return names.isEmpty ? "-" : names.joined(separator: ",")
  }

  private static func text(_ value: JSONValue?, fallback: String = "") -> String {
    guard case .string(let string)? = value else { return fallback }
    return string.isEmpty ? fallback : string
  }
}
