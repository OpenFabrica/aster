import Foundation
import Testing

@testable import AsterCore

/// `aster mcp` 协议层：握手、工具目录与「工具参数 → 控制请求」映射。
struct AgentHostMCPToolsTests {
  /// 记录注入的控制调用，并返回预设结果。注入的闭包是同步、非 @Sendable 的，无需加锁。
  final class CallRecorder {
    var calls: [(method: String, params: JSONValue)] = []
    var result: JSONValue = .object([:])
  }

  private func makeTools(pane: String? = "p_1") -> AgentHostMCPTools {
    AgentHostMCPTools(sessionKey: "mcp:test", callerPane: pane)
  }

  private func request(_ method: String, id: Int? = 1, params: JSONValue? = nil) -> JSONRPCRequest {
    JSONRPCRequest(id: id.map(JSONRPCID.number), method: method, params: params)
  }

  /// 调一次工具，返回 tool result 与记录到的控制调用。
  private func callTool(
    _ tools: inout AgentHostMCPTools, _ name: String, _ arguments: JSONValue
  ) -> (result: JSONValue?, recorder: CallRecorder) {
    let recorder = CallRecorder()
    let response = tools.handle(request("tools/call", params: ["name": .string(name), "arguments": arguments])) {
      method, params in
      recorder.calls.append((method, params))
      return recorder.result
    }
    return (response?.result, recorder)
  }

  @Test("initialize 记录清洗后的 clientInfo.name，并回 aster serverInfo 与协议版本")
  func initializeRecordsClientName() throws {
    var tools = makeTools()
    let response = tools.handle(
      request("initialize", params: ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code\u{1B}[0m"]])
    ) { _, _ in .null }
    #expect(response?.result?["protocolVersion"] == "2025-06-18")
    #expect(response?.result?["serverInfo"]?["name"] == "aster")
    #expect(tools.clientName == "claude-code[0m")
    #expect(tools.caller == AgentHostCaller(session: "mcp:test", client: "claude-code[0m", callerPane: "p_1"))

    _ = tools.handle(request("initialize", params: ["clientInfo": ["name": .string(String(repeating: "é", count: 40))]])) {
      _, _ in .null
    }
    #expect(tools.clientName?.utf8.count == 64)
  }

  @Test("未握手时 client 退回 mcp；非法 caller_pane 被丢弃")
  func callerDefaults() {
    #expect(makeTools().caller.client == "mcp")
    #expect(makeTools(pane: "bad\npane").callerPane == nil)
    #expect(makeTools(pane: "").callerPane == nil)
  }

  @Test("notification 不回包；ping 回空对象；未知方法 -32601")
  func protocolBasics() {
    var tools = makeTools()
    #expect(tools.handle(request("notifications/initialized", id: nil)) { _, _ in .null } == nil)
    #expect(tools.handle(request("notifications/cancelled", id: nil)) { _, _ in .null } == nil)
    #expect(tools.handle(request("unknown/notification", id: nil)) { _, _ in .null } == nil)
    #expect(tools.handle(request("ping")) { _, _ in .null }?.result == .object([:]))
    #expect(tools.handle(request("resources/list")) { _, _ in .null }?.error?.code == -32601)
  }

  @Test("tools/list：名称顺序、必填参数与 annotations")
  func toolsList() throws {
    var tools = makeTools()
    let list = try #require(tools.handle(request("tools/list")) { _, _ in .null }?.result?["tools"]?.arrayValue)
    #expect(list.compactMap { $0["name"]?.stringValue }
      == ["list_hosts", "host_exec", "host_wait", "host_read", "host_interrupt", "host_close"])
    let byName = Dictionary(uniqueKeysWithValues: list.map { ($0["name"]?.stringValue ?? "", $0) })
    #expect(byName["list_hosts"]?["annotations"]?["readOnlyHint"] == true)
    #expect(byName["host_exec"]?["annotations"]?["destructiveHint"] == true)
    #expect(byName["host_exec"]?["annotations"]?["openWorldHint"] == true)
    #expect(byName["host_exec"]?["inputSchema"]?["required"] == ["host", "command"])
    let timeout = byName["host_exec"]?["inputSchema"]?["properties"]?["timeout_seconds"]
    #expect(timeout?["type"] == "integer")
    #expect(timeout?["minimum"] == 1)
    #expect(timeout?["maximum"] == 50)
    #expect(byName["host_wait"]?["inputSchema"]?["required"] == ["command_id"])
    let description = byName["host_exec"]?["description"]?.stringValue ?? ""
    #expect(description.contains("persistent"))
    #expect(description.contains("needs_input"))
  }

  @Test("host_exec 参数精确映射：会话键、client、caller_pane、timeout_ms")
  func hostExecMapsArguments() throws {
    var tools = makeTools()
    _ = tools.handle(request("initialize", params: ["clientInfo": ["name": "codex"]])) { _, _ in .null }
    let (_, recorder) = callTool(
      &tools, "host_exec", ["host": " web ", "command": "cd /srv\r\nls", "reason": "check", "timeout_seconds": 30])
    let call = try #require(recorder.calls.first)
    #expect(call.method == "host.exec")
    let params = try call.params.decoded(as: HostExecParams.self)
    #expect(
      params
        == HostExecParams(
          host: "web", command: "cd /srv\nls",
          agent: AgentHostCaller(session: "mcp:test", client: "codex", callerPane: "p_1"),
          reason: "check", timeoutMs: 30_000))
    #expect(call.params["agent"]?["caller_pane"] == "p_1")

    let (_, defaults) = callTool(&tools, "host_exec", ["host": "web", "command": "uptime", "timeout_seconds": "12"])
    #expect(try defaults.calls.first?.params.decoded(as: HostExecParams.self).timeoutMs == 12_000)
    let (_, omitted) = callTool(&tools, "host_exec", ["host": "web", "command": "uptime"])
    #expect(omitted.calls.first?.params["timeout_ms"] == 40_000)
  }

  @Test("其余工具映射到对应控制方法")
  func otherToolsMapToMethods() throws {
    var tools = makeTools()
    #expect(callTool(&tools, "list_hosts", [:]).recorder.calls.first?.method == "host.list")

    let wait = try #require(callTool(&tools, "host_wait", ["command_id": "c-0123456789ab"]).recorder.calls.first)
    #expect(wait.method == "host.wait")
    #expect(wait.params["command_id"] == "c-0123456789ab")
    #expect(wait.params["timeout_ms"] == 40_000)

    let read = try #require(callTool(&tools, "host_read", ["host": "web", "lines": 20]).recorder.calls.first)
    #expect(read.method == "host.read")
    #expect(try read.params.decoded(as: HostReadParams.self).lines == 20)

    let interrupt = try #require(callTool(&tools, "host_interrupt", ["host": "web"]).recorder.calls.first)
    #expect(interrupt.method == "host.interrupt")
    #expect(interrupt.params["host"] == "web")
    #expect(interrupt.params["agent"]?["session"] == "mcp:test")

    #expect(callTool(&tools, "host_close", ["host": "web"]).recorder.calls.first?.method == "host.close")
  }

  /// 非法参数用例：越界 / 非整数超时、缺参、控制字符、非对象 arguments、未知工具。
  static let invalidCases: [(String, JSONValue)] = [
    ("host_exec", ["host": "web", "command": "ls", "timeout_seconds": 0]),
    ("host_exec", ["host": "web", "command": "ls", "timeout_seconds": 51]),
    ("host_exec", ["host": "web", "command": "ls", "timeout_seconds": 2.5]),
    ("host_exec", ["host": "web"]),
    ("host_exec", ["command": "ls"]),
    ("host_exec", ["host": "web", "command": "printf '\u{1B}[0m'"]),
    ("host_exec", ["host": "web\nx", "command": "ls"]),
    ("host_wait", ["command_id": "c-0123 bad"]),
    ("host_read", ["host": "web", "lines": 501]),
    ("host_close", "not-an-object"),
    ("no_such_tool", [:]),
  ]

  @Test("参数非法时返回 isError 且不发控制请求", arguments: invalidCases)
  func invalidArgumentsAreToolErrors(tool: String, arguments: JSONValue) {
    var tools = makeTools()
    let (result, recorder) = callTool(&tools, tool, arguments)
    #expect(result?["isError"] == true)
    #expect(recorder.calls.isEmpty)
  }
}
