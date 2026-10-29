import Foundation
import Testing

@testable import AsterCore

/// `aster mcp` 的标签 / Pane 列表工具与插件命令工具：参数 → 控制请求、结果投影与渲染。
struct AgentHostMCPWorkspaceToolsTests {
  private func makeTools(pane: String? = "w1:p1", cwd: String? = "/work") -> AgentHostMCPTools {
    AgentHostMCPTools(sessionKey: "mcp:test", callerPane: pane, workingDirectory: cwd)
  }

  /// 调一次工具：返回 tool result 与收到的 (method, params)。
  private func call(
    _ tools: inout AgentHostMCPTools, _ name: String, _ arguments: JSONValue = .object([:]),
    result: JSONValue = .object([:])
  ) -> (result: JSONValue?, calls: [(String, JSONValue)]) {
    var calls: [(String, JSONValue)] = []
    let request = JSONRPCRequest(
      id: .number(1), method: "tools/call", params: ["name": .string(name), "arguments": arguments])
    let response = tools.handle(request) { method, params in
      calls.append((method, params))
      return result
    }
    return (response?.result, calls)
  }

  private func text(_ result: JSONValue?) -> String {
    result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
  }

  @Test("tools/list 追加四个工具，列表工具只读，run_plugin_tool 必填 id")
  func catalog() throws {
    let list = AgentHostMCPToolCatalog.listPayload
    #expect(list.compactMap { $0["name"]?.stringValue }.suffix(4)
      == ["list_tabs", "list_panes", "list_plugin_tools", "run_plugin_tool"])
    let byName = Dictionary(uniqueKeysWithValues: list.map { ($0["name"]?.stringValue ?? "", $0) })
    for name in ["list_tabs", "list_panes", "list_plugin_tools"] {
      #expect(byName[name]?["annotations"]?["readOnlyHint"] == true)
    }
    #expect(byName["run_plugin_tool"]?["inputSchema"]?["required"] == ["id"])
    #expect(AgentHostMCPToolCatalog.names.count == list.count)
  }

  @Test("list_tabs / list_panes 取 session.snapshot 并在本地筛选；current 换成调用者 Pane")
  func layoutLists() throws {
    var tools = makeTools(pane: "w2:p1")
    let snapshot = try JSONValue(encoding: SessionLayoutListingTests.snapshot)

    let tabs = call(&tools, "list_tabs", result: snapshot)
    #expect(tabs.calls.map(\.0) == ["session.snapshot"])
    #expect(tabs.result?["structuredContent"]?["tabs"]?.arrayValue?.count == 3)
    #expect(text(tabs.result).hasPrefix("TAB     WINDOW"))

    let mine = call(&tools, "list_panes", ["tab": "current"], result: snapshot)
    #expect(mine.result?["structuredContent"]?["panes"]?.arrayValue?.compactMap { $0["pane_id"]?.stringValue } == ["w2:p1"])

    let window = call(&tools, "list_tabs", ["window": "w1"], result: snapshot)
    #expect(window.result?["structuredContent"]?["tabs"]?.arrayValue?.count == 2)

    let missing = call(&tools, "list_panes", ["tab": "w7:t1"], result: snapshot)
    #expect(missing.result?["isError"] == true)
    #expect(text(missing.result).contains("not_found"))
    #expect(text(missing.result).contains("list_tabs"))

    // 坏参数在本地拒绝，不连 socket。
    let bad = call(&tools, "list_panes", ["tab": .number(3)], result: snapshot)
    #expect(bad.calls.isEmpty)
    #expect(text(bad.result).contains("invalid arguments"))
  }

  @Test("list_plugin_tools → tool.list；结果逐条渲染，不能运行时带原因")
  func listPluginTools() throws {
    var tools = makeTools()
    let result = try JSONValue(
      encoding: ToolListResult(tools: [
        ToolCommandInfo(
          id: "aster.text/hash", pluginID: "aster.text", pluginName: "文本", title: "SHA-256", kind: .builtin,
          status: .ready, runnable: true),
        ToolCommandInfo(
          id: "com.x/ui", pluginID: "com.x", pluginName: "X", title: "面板", kind: .ui, status: .ready, runnable: false,
          unavailableReason: "has a web UI"),
      ]))
    let listed = call(&tools, "list_plugin_tools", ["query": "hash"], result: result)
    #expect(listed.calls.first?.0 == "tool.list")
    #expect(listed.calls.first?.1["query"] == "hash")
    #expect(text(listed.result).contains("- aster.text/hash — SHA-256 (文本) · builtin · runnable"))
    #expect(text(listed.result).contains("not runnable: has a web UI"))
  }

  @Test("run_plugin_tool → tool.run：input 原样、cwd 缺省取 MCP 进程目录；坏 id 本地拒绝")
  func runPluginTool() throws {
    var tools = makeTools()
    let output = try JSONValue(encoding: ToolRunResult(id: "p.x/a", output: "text", text: "hi", durationMs: 1200))
    let ran = call(&tools, "run_plugin_tool", ["id": "p.x/a", "input": "  a\nb  "], result: output)
    #expect(ran.calls.first?.0 == "tool.run")
    #expect(ran.calls.first?.1["input"] == "  a\nb  ")
    #expect(ran.calls.first?.1["cwd"] == "/work")
    #expect(text(ran.result) == "text · duration 1.2s\n```\nhi\n```")

    let explicit = call(&tools, "run_plugin_tool", ["id": "p.x/a", "cwd": "/tmp"], result: output)
    #expect(explicit.calls.first?.1["cwd"] == "/tmp")

    for bad: JSONValue in [["id": "no-slash"], [:], ["id": "p.x/a", "cwd": "relative"]] {
      let rejected = call(&tools, "run_plugin_tool", bad, result: output)
      #expect(rejected.calls.isEmpty)
      #expect(rejected.result?["isError"] == true)
    }
    // 工作目录不是绝对路径就当没有。
    #expect(makeTools(cwd: "relative").workingDirectory == nil)
  }

  @Test("run_plugin_tool 渲染 list / none 结果；旧版 App 不认 tool.* 时提示升级")
  func runRenderingAndOldApp() throws {
    let list = ToolRunResult(
      id: "p.x/a", output: "list", items: [ToolListItem(title: "one", subtitle: "first", value: "1")], durationMs: 0)
    #expect(AgentHostMCPRendering.pluginToolRun(list) == "list · duration 0.0s\n- one — first\n  value: 1")
    #expect(AgentHostMCPRendering.pluginToolRun(ToolRunResult(id: "p.x/a", output: "none", durationMs: 0)).hasSuffix("Done."))

    var tools = makeTools()
    let request = JSONRPCRequest(
      id: .number(1), method: "tools/call", params: ["name": "list_plugin_tools", "arguments": .object([:])])
    let response = tools.handle(request) { _, _ in
      throw AsterControlError(code: .methodNotFound, message: "未知方法: tool.list")
    }
    let message = text(response?.result)
    #expect(message.contains("update Aster"))
  }
}
