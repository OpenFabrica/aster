import Foundation
import Testing

@testable import AsterCore

/// `aster mcp` 结果渲染：状态首行、围栏输出、structuredContent 与错误提示。
struct AgentHostMCPToolsRenderingTests {
  /// 用给定的控制调用行为跑一次工具，返回 tool result。
  private func run(
    _ tool: String, _ arguments: JSONValue, call: @escaping AgentHostMCPTools.ControlCall
  ) -> JSONValue? {
    var tools = AgentHostMCPTools(sessionKey: "mcp:test", callerPane: nil)
    return tools.handle(
      JSONRPCRequest(id: .number(9), method: "tools/call", params: ["name": .string(tool), "arguments": arguments]),
      call: call)?.result
  }

  private func text(_ result: JSONValue?) -> String {
    result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
  }

  private func execResult(_ result: HostExecResult) throws -> JSONValue? {
    let raw = try JSONValue(encoding: result)
    return run("host_exec", ["host": "web", "command": "ls"]) { _, _ in raw }
  }

  @Test("completed：首行状态 · 退出码 · 耗时，随后围栏输出；structuredContent 为原结果")
  func completedRendering() throws {
    let raw = HostExecResult(
      commandID: "c-0123456789ab", terminalID: "t-0123456789ab", hostID: "h1", hostName: "web",
      status: .completed, exitCode: 0, output: "a\nb", durationMs: 1_234)
    let result = try execResult(raw)
    #expect(result?["isError"] == nil)
    #expect(text(result) == "completed · exit_code 0 · duration 1.2s\n```\na\nb\n```")
    #expect(result?["structuredContent"] == (try JSONValue(encoding: raw)))
    #expect(result?["structuredContent"]?["command_id"] == "c-0123456789ab")
  }

  @Test("running：带 command_id 与 host_wait 指引；截断时附说明")
  func runningRendering() throws {
    let result = try execResult(
      HostExecResult(
        commandID: "c-0123456789ab", terminalID: "t-1", hostID: "h1", hostName: "web", status: .running,
        output: "", outputTruncated: true, durationMs: 40_000))
    let lines = text(result).split(separator: "\n").map(String.init)
    #expect(lines.first == "running · duration 40.0s · command_id c-0123456789ab")
    #expect(text(result).contains("host_wait"))
    #expect(text(result).contains("(output truncated"))
    #expect(lines.last == "(no output)")
  }

  @Test("needs_input：带 prompt 行与「让用户在 Aster 窗口回答」")
  func needsInputRendering() throws {
    let result = try execResult(
      HostExecResult(
        commandID: "c-0123456789ab", terminalID: "t-1", hostID: "h1", hostName: "web", status: .needsInput,
        output: "Reading package lists...", prompt: "[sudo] password for deploy:", durationMs: 2_000))
    let rendered = text(result)
    #expect(rendered.hasPrefix("needs_input · duration 2.0s · command_id c-0123456789ab\n"))
    #expect(rendered.contains("prompt: [sudo] password for deploy:"))
    #expect(rendered.contains("Aster window"))
  }

  @Test("输出含 ``` 时围栏加长，不会提前闭合")
  func fenceGrowsPastBackticks() {
    #expect(AgentHostMCPRendering.fenced("x ```` y") == "`````\nx ```` y\n`````")
  }

  @Test("list_hosts 渲染名称、目标、分组、id 与 agentAccess")
  func hostListRendering() {
    let result = run("list_hosts", [:]) { _, _ in
      ["hosts": [
        ["id": "h1", "name": "web", "target": "deploy@web:22", "group": "prod", "agentAccess": "ask"],
        ["id": "h2", "name": "db", "target": "db:22"],
      ]]
    }
    #expect(text(result) == "- web — deploy@web:22 · group prod · id h1 · agentAccess ask\n- db — db:22 · id h2")
  }

  /// 错误码与提示里必须出现的关键词。
  static let hintCases: [(AsterControlErrorCode, String)] = [
    (.approvalPending, "retry host_exec shortly"),
    (.approvalDenied, "do not retry"),
    (.agentAccessDisabled, "Allow coding agents to request host access"),
    (.agentPaused, "paused"),
    (.hostNotReady, "not become ready"),
    (.paneBusy, "host_interrupt"),
    (.limitExceeded, "host_close"),
    (.terminalEnded, "host_exec again"),
    (.notFound, "list_hosts"),
    (.ambiguousTarget, "list_hosts"),
  ]

  @Test("服务端错误码：isError + `code: message` + 可执行提示", arguments: hintCases)
  func controlErrorsCarryHints(code: AsterControlErrorCode, hint: String) {
    let result = run("host_exec", ["host": "web", "command": "ls"]) { _, _ in
      throw AsterControlError(code: code, message: "boom")
    }
    #expect(result?["isError"] == true)
    #expect(text(result).hasPrefix("\(code.rawValue): boom\nHint: "))
    #expect(text(result).contains(hint))
  }

  @Test("host_wait 的 not_found 提示 command_id 过期而不是 list_hosts")
  func waitNotFoundHint() {
    let result = run("host_wait", ["command_id": "c-0123456789ab"]) { _, _ in
      throw AsterControlError(code: .notFound, message: "gone")
    }
    #expect(text(result).contains("unknown or expired"))
  }

  @Test("App 不可达：isError 且提示 Aster 没在运行")
  func unreachableRendering() {
    let result = run("list_hosts", [:]) { _, _ in throw AgentHostMCPUnreachableError(message: "no socket") }
    #expect(result?["isError"] == true)
    #expect(text(result).hasPrefix("aster_unreachable: no socket"))
    #expect(text(result).contains("Aster is not running"))
  }
}
