// `aster mcp` 的结果渲染：把控制方法的 result / error 转成 MCP tool result。
// 文本给 agent 读（首行是状态摘要，随后是围栏输出），`structuredContent` 原样带上结果对象。
import Foundation

/// MCP tool result 的渲染。
enum AgentHostMCPRendering {
  // MARK: - 成功

  /// 按工具渲染成功结果；结果形状不认识时退回漂亮打印的 JSON，不丢信息。
  static func success(tool: String, result: JSONValue) -> JSONValue {
    let text: String
    switch tool {
    case AgentHostMCPToolCatalog.Name.listHosts:
      text = hostList(result)
    case AgentHostMCPToolCatalog.Name.hostExec, AgentHostMCPToolCatalog.Name.hostWait,
      AgentHostMCPToolCatalog.Name.hostInterrupt:
      text = (try? result.decoded(as: HostExecResult.self)).map(execResult) ?? rawJSON(result)
    case AgentHostMCPToolCatalog.Name.hostRead:
      text = (try? result.decoded(as: HostReadResult.self)).map(readResult) ?? rawJSON(result)
    case AgentHostMCPToolCatalog.Name.hostClose:
      text = "Closed the agent terminal on this host."
    case AgentHostMCPToolCatalog.Name.listTabs:
      text = (try? result.decoded(as: SessionLayoutListing.TabListResult.self))
        .map { SessionLayoutListing.renderTabs($0.tabs) } ?? rawJSON(result)
    case AgentHostMCPToolCatalog.Name.listPanes:
      text = (try? result.decoded(as: SessionLayoutListing.PaneListResult.self))
        .map { SessionLayoutListing.renderPanes($0.panes) } ?? rawJSON(result)
    case AgentHostMCPToolCatalog.Name.listPluginTools:
      text = (try? result.decoded(as: ToolListResult.self)).map(pluginToolList) ?? rawJSON(result)
    case AgentHostMCPToolCatalog.Name.runPluginTool:
      text = (try? result.decoded(as: ToolRunResult.self)).map(pluginToolRun) ?? rawJSON(result)
    default:
      text = rawJSON(result)
    }
    var payload: [String: JSONValue] = ["content": .array([textContent(text)])]
    // MCP 要求 structuredContent 是对象；其它形状只放进文本。
    if case .object = result { payload["structuredContent"] = result }
    return .object(payload)
  }

  /// 执行结果：首行「状态 · 退出码 · 耗时」，必要时附下一步指引，再接围栏输出。
  static func execResult(_ result: HostExecResult) -> String {
    var summary = [result.status.rawValue]
    if let exitCode = result.exitCode { summary.append("exit_code \(exitCode)") }
    summary.append("duration \(seconds(result.durationMs))")
    if result.status == .running || result.status == .needsInput {
      summary.append("command_id \(result.commandID)")
    }
    var lines = [summary.joined(separator: " · ")]
    switch result.status {
    case .running:
      lines.append("Still running. Call host_wait with command_id \(result.commandID) to keep waiting.")
    case .needsInput:
      if let prompt = result.prompt, !prompt.isEmpty { lines.append("prompt: \(prompt)") }
      lines.append(
        "The command is waiting for input. Tell the user to answer it in the Aster window, then call "
          + "host_wait with command_id \(result.commandID). Do not ask the user for passwords.")
    case .interrupted:
      lines.append("The command was interrupted (Ctrl-C).")
    case .ended:
      lines.append("The terminal ended before the command finished.")
    case .completed:
      break
    }
    if result.outputTruncated { lines.append("(output truncated: the middle was omitted)") }
    lines.append(fenced(result.output))
    return lines.joined(separator: "\n")
  }

  /// 读屏结果：终端 id + 围栏文本。
  static func readResult(_ result: HostReadResult) -> String {
    "terminal \(result.terminalID)\n" + fenced(result.text)
  }

  /// 主机列表：一行一台，`name — target`，后接分组、id 与 agent 访问策略。
  static func hostList(_ result: JSONValue) -> String {
    var lines: [String] = []
    if let error = result["configurationError"]?.stringValue {
      lines.append("! hosts.json failed to load: \(error) (showing the last valid configuration)")
    }
    let hosts = result["hosts"]?.arrayValue ?? []
    if hosts.isEmpty { lines.append("No SSH hosts are saved in Aster. Ask the user to add one in Aster.") }
    for host in hosts {
      var line = "- \(host["name"]?.stringValue ?? "?") — \(host["target"]?.stringValue ?? "?")"
      if let group = host["group"]?.stringValue, !group.isEmpty { line += " · group \(group)" }
      line += " · id \(host["id"]?.stringValue ?? "?")"
      if let access = host["agentAccess"]?.stringValue, !access.isEmpty { line += " · agentAccess \(access)" }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  /// 插件命令列表：一行一条，`id — 标题 (插件)`，后接种类与能否运行；不能运行时给出原因。
  static func pluginToolList(_ result: ToolListResult) -> String {
    guard !result.tools.isEmpty else { return "No plugin commands match." }
    return result.tools.map { tool in
      var line = "- \(tool.id) — \(tool.title) (\(tool.pluginName))"
      line += " · " + ([tool.kind.rawValue] + [tool.output].compactMap { $0 }).joined(separator: "/")
      if tool.runnable {
        line += " · runnable"
      } else {
        line += " · not runnable"
        if let reason = tool.unavailableReason, !reason.isEmpty { line += ": \(reason)" }
      }
      if let subtitle = tool.subtitle, !subtitle.isEmpty { line += "\n  \(subtitle)" }
      return line
    }.joined(separator: "\n")
  }

  /// 插件命令结果：首行「输出方式 · 耗时」，再接文本（围栏）或列表项；`none` 只报完成。
  static func pluginToolRun(_ result: ToolRunResult) -> String {
    var lines = ["\(result.output) · duration \(seconds(result.durationMs))"]
    switch result.output {
    case "list":
      let items = result.items ?? []
      if items.isEmpty { lines.append("(no items)") }
      for item in items {
        var line = "- \(item.title)"
        if let subtitle = item.subtitle, !subtitle.isEmpty { line += " — \(subtitle)" }
        if let value = item.value, value != item.title { line += "\n  value: \(value)" }
        lines.append(line)
      }
    case "none":
      lines.append("Done.")
    default:
      if result.truncated { lines.append("(output truncated)") }
      lines.append(fenced(result.text ?? ""))
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - 错误

  /// 服务端错误：`code: message`，再附一行可执行的下一步建议。
  static func controlError(_ error: AsterControlError, tool: String) -> JSONValue {
    var text = "\(error.code.rawValue): \(error.message)"
    if let hint = hint(for: error.code, tool: tool) { text += "\nHint: \(hint)" }
    return self.error(text)
  }

  /// App 不可达。
  static func unreachable(_ error: AgentHostMCPUnreachableError) -> JSONValue {
    self.error(
      "aster_unreachable: \(error.message)\nHint: Aster is not running (or did not respond). "
        + "Ask the user to open the Aster app, then retry.")
  }

  /// 每个错误码给 agent 的下一步建议；没有可执行建议的码返回 nil。
  static func hint(for code: AsterControlErrorCode, tool: String) -> String? {
    switch code {
    case .approvalPending:
      return "The user has not answered the approval prompt in Aster yet; retry host_exec shortly."
    case .approvalDenied:
      return "The user denied access to this host; do not retry, ask the user."
    case .agentAccessDisabled:
      return "Ask the user to enable 'Allow coding agents to request host access' in Aster Settings → "
        + "Hosts → Agent Access."
    case .agentPaused:
      return "The user paused the agent in the Aster window; stop and ask the user how to proceed."
    case .hostNotReady:
      return "The SSH terminal did not become ready (still connecting, waiting for authentication, or "
        + "the connection failed). Check with the user, then retry."
    case .paneBusy:
      return "Another command is still running in this host terminal. Call host_wait with its "
        + "command_id, or host_interrupt to stop it."
    case .limitExceeded:
      return "Too many agent terminals or queued commands. Close terminals you no longer need with "
        + "host_close, or wait for running commands to finish."
    case .terminalEnded:
      return "The agent terminal for this host has ended. Call host_exec again to open a new one "
        + "(shell state was lost)."
    case .methodNotFound
    where tool == AgentHostMCPToolCatalog.Name.listPluginTools || tool == AgentHostMCPToolCatalog.Name.runPluginTool:
      return "This version of the Aster app does not support plugin commands yet; ask the user to update Aster."
    case .notFound where tool == AgentHostMCPToolCatalog.Name.runPluginTool:
      return "Call list_plugin_tools and pass an exact command id."
    case .notFound where tool == AgentHostMCPToolCatalog.Name.listTabs:
      return "Call list_tabs without a window to see every window."
    case .notFound where tool == AgentHostMCPToolCatalog.Name.listPanes:
      return "Call list_tabs to get valid tab ids, or list_panes without a tab."
    case .notFound where tool == AgentHostMCPToolCatalog.Name.hostWait:
      return "The command_id is unknown or expired. Use host_read to inspect the terminal, or run the "
        + "command again."
    case .notFound, .ambiguousTarget:
      return "Call list_hosts and pass an exact host name or id."
    case .invalidParams:
      return "Fix the arguments and retry."
    default:
      return nil
    }
  }

  // MARK: - 基础构件

  /// `isError: true` 的 tool result（MCP 约定：工具错误放在 result 里，让 agent 读到原因）。
  static func error(_ message: String) -> JSONValue {
    .object(["content": .array([textContent(message)]), "isError": true])
  }

  /// 单个 text content 块。
  private static func textContent(_ text: String) -> JSONValue {
    .object(["type": "text", "text": .string(text)])
  }

  /// 毫秒 → `1.2s`。
  static func seconds(_ milliseconds: Int) -> String {
    String(format: "%.1fs", Double(max(milliseconds, 0)) / 1_000)
  }

  /// 围栏代码块。围栏比输出里最长的连续反引号多一个，输出里有 ``` 也不会提前闭合。
  static func fenced(_ text: String) -> String {
    guard !text.isEmpty else { return "(no output)" }
    var longest = 0
    var current = 0
    for character in text {
      current = character == "`" ? current + 1 : 0
      longest = max(longest, current)
    }
    let fence = String(repeating: "`", count: max(3, longest + 1))
    return "\(fence)\n\(text)\n\(fence)"
  }

  /// 不认识的结果形状：排序键的漂亮 JSON。
  private static func rawJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
  }
}
