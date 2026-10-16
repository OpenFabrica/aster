import Foundation
import Testing

@testable import AsterCore

/// `host.*` agent 远程执行的线格式：参数与结果的 snake_case 键名与往返。
struct AgentHostControlProtocolTests {
  private let caller = AgentHostCaller(session: "s1", client: "codex", callerPane: "p_1")

  /// 排序键编码成字符串，便于逐字比对线格式。
  private func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
  }

  @Test("方法名与 host.* 线格式一致")
  func methodNames() {
    #expect(AgentHostControlMethod.allCases.map(\.rawValue)
      == ["host.open", "host.exec", "host.wait", "host.read", "host.interrupt", "host.close", "host.terminals"])
  }

  @Test("HostExecParams 编码为 snake_case，并能从同一 JSON 解回")
  func execParamsRoundTrip() throws {
    let params = HostExecParams(
      host: "web", command: "ls -la", agent: caller, reason: "why", timeoutMs: 30_000, maxOutputBytes: 1_024)
    let expected =
      #"{"agent":{"caller_pane":"p_1","client":"codex","session":"s1"},"command":"ls -la","host":"web","#
      + #""max_output_bytes":1024,"reason":"why","timeout_ms":30000}"#
    #expect(try json(params) == expected)
    #expect(try decode(HostExecParams.self, expected) == params)

    let minimal = try decode(HostExecParams.self, #"{"host":"web","command":"ls","agent":{"session":"s"}}"#)
    #expect(minimal.agent == AgentHostCaller(session: "s"))
    #expect(minimal.timeoutMs == nil)
    #expect(minimal.maxOutputBytes == nil)
  }

  @Test("wait / read / interrupt / close / open / terminals 参数键名")
  func otherParamKeys() throws {
    let agent = #""agent":{"caller_pane":"p_1","client":"codex","session":"s1"}"#
    #expect(
      try json(HostWaitParams(commandID: "c-0123456789ab", agent: caller, timeoutMs: 5, maxOutputBytes: 7))
        == #"{\#(agent),"command_id":"c-0123456789ab","max_output_bytes":7,"timeout_ms":5}"#)
    #expect(
      try json(HostReadParams(terminalID: "t-0123456789ab", agent: caller, lines: 20))
        == #"{\#(agent),"lines":20,"terminal_id":"t-0123456789ab"}"#)
    #expect(
      try json(HostInterruptParams(commandID: "c-0123456789ab", agent: caller))
        == #"{\#(agent),"command_id":"c-0123456789ab"}"#)
    #expect(try json(HostCloseParams(host: "web", agent: caller)) == #"{\#(agent),"host":"web"}"#)
    #expect(try json(HostOpenParams(host: "web", agent: caller, timeoutMs: 9)) == #"{\#(agent),"host":"web","timeout_ms":9}"#)
    #expect(try json(HostTerminalsParams(agent: caller)) == #"{\#(agent)}"#)
    #expect(throws: (any Error).self) { try decode(HostTerminalsParams.self, "{}") }
    #expect(try decode(HostReadParams.self, #"{"host":"web","agent":{"session":"s"},"lines":3}"#).lines == 3)
  }

  @Test("HostExecResult 编码键名与 needs_input 状态")
  func execResultKeys() throws {
    let result = HostExecResult(
      commandID: "c-0123456789ab", terminalID: "t-0123456789ab", hostID: "h1", hostName: "web",
      status: .needsInput, output: "x", outputTruncated: true, prompt: "Password:", durationMs: 12)
    let encoded = try json(result)
    #expect(
      encoded
        == #"{"command_id":"c-0123456789ab","duration_ms":12,"host_id":"h1","host_name":"web","output":"x","#
        + #""output_truncated":true,"prompt":"Password:","status":"needs_input","terminal_id":"t-0123456789ab"}"#)
    #expect(try decode(HostExecResult.self, encoded) == result)

    let completed = HostExecResult(
      commandID: "c-1", terminalID: "t-1", hostID: "h", hostName: "n", status: .completed, exitCode: 3)
    #expect(try json(completed).contains(#""exit_code":3"#))
  }

  @Test("终端列表与读屏结果键名")
  func terminalAndReadResultKeys() throws {
    let info = HostTerminalInfo(
      terminalID: "t-1", hostID: "h", hostName: "web", target: "u@web:22", state: .needsInput,
      runningCommandID: "c-1")
    #expect(
      try json(HostTerminalsResult(terminals: [info]))
        == #"{"terminals":[{"host_id":"h","host_name":"web","running_command_id":"c-1","#
        + #""state":"needs_input","target":"u@web:22","terminal_id":"t-1"}]}"#)
    #expect(try json(HostReadResult(terminalID: "t-1", text: "$ ")) == #"{"terminal_id":"t-1","text":"$ "}"#)
  }
}
