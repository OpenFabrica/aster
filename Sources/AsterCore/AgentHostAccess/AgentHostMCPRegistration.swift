// 检查 Claude Code / Codex 配置里已登记的 `aster` MCP 命令是否还可靠。
// 早期版本会把 App 包内 aster-cli 的绝对路径写进配置，开发构建删除或换装正式版后路径失效，
// 客户端启动时就报错；设置页据此提示「修复」，改写成稳定的 `aster` 命令路径。
import Foundation

/// 已登记 MCP 命令的解析与判定（纯函数，只读配置文本，不改任何文件）。
public enum AgentHostMCPRegistration {
  /// 登记状态。
  public enum Status: String, Sendable, Equatable {
    /// 没有登记 `aster` 这个 MCP server。
    case notRegistered
    /// 登记的命令就是稳定路径，且可执行。
    case ok
    /// 登记了，但写的是会失效的路径（App 包内、已不存在，或不是当前稳定路径）。
    case needsRepair
  }

  /// 从 `~/.claude.json` 内容取用户级 `mcpServers.<name>.command`；没有或解析失败返回 nil。
  public static func claudeCommand(fromJSON data: Data, serverName: String = "aster") -> String? {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let servers = root["mcpServers"] as? [String: Any],
      let server = servers[serverName] as? [String: Any]
    else { return nil }
    return server["command"] as? String
  }

  /// 从 Codex `config.toml` 文本取 `[mcp_servers.<name>]` 段的 `command`；没有返回 nil。
  /// 只处理 `codex mcp add` 写出的形状（基本字符串或字面字符串），不是通用 TOML 解析器。
  public static func codexCommand(fromTOML text: String, serverName: String = "aster") -> String? {
    let headers: Set<String> = ["[mcp_servers.\(serverName)]", "[mcp_servers.\"\(serverName)\"]"]
    var inSection = false
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        inSection = headers.contains(line)
        continue
      }
      guard inSection, line.hasPrefix("command") else { continue }
      let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2, parts[0] == "command" else { continue }
      return unquote(parts[1])
    }
    return nil
  }

  /// 判定登记状态。`stablePath` 是当前的 `aster` symlink 路径（未安装时为 nil）。
  public static func status(
    command: String?, stablePath: String?, isExecutable: (String) -> Bool
  ) -> Status {
    guard let command, !command.isEmpty else { return .notRegistered }
    if let stablePath { return command == stablePath && isExecutable(command) ? .ok : .needsRepair }
    // 还没装稳定命令时：指向 App 包内或已不存在的路径都会失效。
    return command.contains(".app/Contents/MacOS/") || !isExecutable(command) ? .needsRepair : .ok
  }

  /// 去掉 TOML 字符串的引号：`"…"` 处理 `\"` 与 `\\` 转义，`'…'` 原样；其它形状返回 nil。
  private static func unquote(_ value: String) -> String? {
    if value.count >= 2, value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") {
      return String(value[value.index(after: value.startIndex)..<end])
    }
    guard value.hasPrefix("\"") else { return nil }
    var result = ""
    var escaped = false
    for character in value.dropFirst() {
      if escaped {
        result.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        return result
      } else {
        result.append(character)
      }
    }
    return nil
  }
}
