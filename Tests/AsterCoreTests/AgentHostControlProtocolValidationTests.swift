import Foundation
import Testing

@testable import AsterCore

/// `host.*` 参数的边界校验：会话键、命令文本、输出预算与二选一字段。
struct AgentHostControlProtocolValidationTests {
  private let caller = AgentHostCaller(session: "s1")

  private func exec(_ command: String, maxOutput: Int? = nil) -> HostExecParams {
    HostExecParams(host: "web", command: command, agent: caller, maxOutputBytes: maxOutput)
  }

  /// 期望校验以 invalid_params 失败。
  private func expectInvalid(_ params: some AsterControlValidatable, sourceLocation: SourceLocation = #_sourceLocation) {
    let error = #expect(throws: AsterControlError.self, sourceLocation: sourceLocation) { try params.validate() }
    #expect(error?.code == .invalidParams, sourceLocation: sourceLocation)
  }

  @Test("会话键：空串、超过 128 字节与控制字符被拒；128 字节通过")
  func sessionBounds() throws {
    expectInvalid(AgentHostCaller(session: ""))
    expectInvalid(AgentHostCaller(session: String(repeating: "a", count: 129)))
    expectInvalid(AgentHostCaller(session: "a\u{1B}b"))
    expectInvalid(AgentHostCaller(session: "s", client: "x\ny"))
    expectInvalid(AgentHostCaller(session: "s", client: String(repeating: "c", count: 65)))
    try AgentHostCaller(session: String(repeating: "a", count: 128), client: "claude-code", callerPane: "p_1").validate()
  }

  @Test("命令：ESC / NUL / CR 被拒，换行与 Tab 放行")
  func commandControlCharacters() throws {
    expectInvalid(exec("printf '\u{1B}[31m'"))
    expectInvalid(exec("echo a\u{0}b"))
    expectInvalid(exec("echo a\rb"))
    expectInvalid(exec("   \n "))
    try exec("cd /srv\nprintf 'a\tb'").validate()
  }

  @Test("命令：总长 16 KiB、单行 4000 字节上限")
  func commandLengthBounds() throws {
    try exec(String(repeating: "a", count: 4_000)).validate()
    expectInvalid(exec(String(repeating: "a", count: 4_001)))
    let lines = Array(repeating: String(repeating: "b", count: 3_999), count: 4).joined(separator: "\n")
    try exec(lines).validate()
    expectInvalid(exec(lines + "\n" + String(repeating: "c", count: 400)))
  }

  @Test("max_output_bytes 在 1...1 MiB 之内")
  func maximumOutputBounds() throws {
    try exec("ls", maxOutput: 1).validate()
    try exec("ls", maxOutput: AgentHostLimits.maximumOutputBytesLimit).validate()
    expectInvalid(exec("ls", maxOutput: 0))
    expectInvalid(exec("ls", maxOutput: AgentHostLimits.maximumOutputBytesLimit + 1))
  }

  @Test("host 与 terminal_id / command_id 恰好给一个")
  func exactlyOneTarget() throws {
    try HostReadParams(host: "web", agent: caller).validate()
    try HostReadParams(terminalID: "t-0123456789ab", agent: caller).validate()
    expectInvalid(HostReadParams(host: "web", terminalID: "t-0123456789ab", agent: caller))
    expectInvalid(HostReadParams(agent: caller))
    expectInvalid(HostCloseParams(agent: caller))
    expectInvalid(HostCloseParams(host: "web", terminalID: "t-1", agent: caller))
    try HostInterruptParams(commandID: "c-0123456789ab", agent: caller).validate()
    expectInvalid(HostInterruptParams(commandID: "c-1", host: "web", agent: caller))
    expectInvalid(HostInterruptParams(agent: caller))
    expectInvalid(HostInterruptParams(commandID: "c-01 23", agent: caller))
  }

  @Test("其余边界：host 非空、lines 范围、timeout 不为负、reason 上限")
  func miscBounds() {
    expectInvalid(HostExecParams(host: "", command: "ls", agent: caller))
    expectInvalid(HostExecParams(host: "web\u{7F}", command: "ls", agent: caller))
    expectInvalid(HostReadParams(host: "web", agent: caller, lines: 0))
    expectInvalid(HostReadParams(host: "web", agent: caller, lines: 501))
    expectInvalid(HostWaitParams(commandID: "c-1", agent: caller, timeoutMs: -1))
    expectInvalid(HostWaitParams(commandID: "", agent: caller))
    expectInvalid(HostExecParams(host: "web", command: "ls", agent: caller, reason: String(repeating: "r", count: 513)))
    #expect(AgentHostValidation.clampedTimeout(nil) == AgentHostLimits.defaultTimeoutMilliseconds)
    #expect(AgentHostValidation.clampedTimeout(10_000_000) == AgentHostLimits.maximumTimeoutMilliseconds)
  }
}
