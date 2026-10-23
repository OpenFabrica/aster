// `host.exec` 等 agent 远程执行方法：开关、批准、拒绝冷却、超时重试与审计。
// 终端、批准面板与审计都是替身；执行与等输入的行为见 AgentHostExecutionTests。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Suite("agent 远程执行：授权与批准")
@MainActor
struct AgentHostControlCommandsTests {
  @Test("总开关关着：agent_access_disabled，不弹批准")
  func disabled() async {
    let fixture = AgentHostFixture()
    fixture.surfaces.enabled = false
    let response = await fixture.call("host.exec", AgentHostFixture.exec("uptime"))
    #expect(response.error?.code == .agentAccessDisabled)
    #expect(fixture.approvals.requests.isEmpty)
  }

  @Test("允许一次：执行完成，输出与退出码回传，审计 started + finished，不留授权")
  func allowOnce() async throws {
    let fixture = AgentHostFixture { $0.behavior = { _ in .complete(output: "up 3 days", exitCode: 0) } }
    fixture.approvals.nextAnswer = .allowOnce
    let response = await fixture.call("host.exec", AgentHostFixture.exec("uptime"))
    let result = try #require(response.result).decoded(as: HostExecResult.self)
    #expect(result.status == .completed)
    #expect(result.exitCode == 0)
    #expect(result.output == "up 3 days")
    #expect(result.hostName == "prod-db")
    #expect(result.commandID.hasPrefix("c-"))
    #expect(fixture.approvals.requests.first?.command == "uptime")
    #expect(fixture.audit.actions == [.execStarted, .execFinished])
    #expect(fixture.audit.records.last?.approver?.scope == "once")
    #expect(fixture.audit.records.last?.result?.exitCode == "0")
    #expect(fixture.service.grants.grants.isEmpty)
    // 下一条命令仍要批准。
    fixture.approvals.nextAnswer = nil
    let again = await fixture.call("host.exec", AgentHostFixture.exec("uptime", timeoutMs: 300))
    #expect(again.error?.code == .approvalPending)
  }

  @Test("本会话允许：同会话不再弹窗，其它会话仍要批准")
  func allowSession() async throws {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowSession
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    fixture.approvals.nextAnswer = nil
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    #expect(fixture.approvals.requests.count == 1)
    let other = await fixture.call("host.exec", AgentHostFixture.exec("true", session: "s2", timeoutMs: 300))
    #expect(other.error?.code == .approvalPending)
    #expect(fixture.audit.actions.contains(.grantCreated))
  }

  @Test("拒绝：approval_denied，冷却期内直接拒绝不再弹窗，审计 grant.denied")
  func deny() async {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .deny
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("rm -rf /tmp/x")).error?.code == .approvalDenied)
    fixture.approvals.nextAnswer = .allowAlways
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls")).error?.code == .approvalDenied)
    #expect(fixture.approvals.requests.count == 1)
    #expect(fixture.audit.actions == [.grantDenied])
    #expect(fixture.audit.records[0].actor.account == "tester")
  }

  @Test("批准超时：approval_pending；用户迟到的「允许一次」成为一次性授权，重试直接放行")
  func pendingThenLateAnswer() async throws {
    let fixture = AgentHostFixture()
    let first = await fixture.call("host.exec", AgentHostFixture.exec("ls", timeoutMs: 1_000))
    #expect(first.error?.code == .approvalPending)
    let request = try #require(fixture.approvals.requests.first)
    fixture.approvals.answerLate(request, .allowOnce)
    #expect(fixture.service.grants.grants.map(\.scope) == [.once])
    let retry = await fixture.call("host.exec", AgentHostFixture.exec("ls"))
    #expect(retry.error == nil)
    #expect(fixture.approvals.requests.count == 1)
    #expect(fixture.service.grants.grants.isEmpty)
    #expect(fixture.audit.records.first { $0.action == .execStarted }?.approver?.kind == "grant")
  }

  @Test("一直允许：host.list 标记 always；任意会话放行；撤销后恢复批准")
  func allowAlways() async throws {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowAlways
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    fixture.approvals.nextAnswer = nil
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", session: "other")).error == nil)
    #expect(fixture.service.alwaysGrantedHostIDs().count == 1)
    let grant = try #require(fixture.service.grants.grants.first)
    #expect(fixture.service.grants.revoke(grantID: grant.grantID, by: AgentHostLocalUser(account: "tester", name: "T")))
    let revoked = try #require(fixture.audit.records.last)
    #expect(revoked.action == .grantRevoked)
    #expect(revoked.changes?.allSatisfy { $0.after == AgentHostAuditRecord.Change.deleted } == true)
    let after = await fixture.call("host.exec", AgentHostFixture.exec("true", session: "other", timeoutMs: 300))
    #expect(after.error?.code == .approvalPending)
  }

  @Test("主机解析：不存在 not_found，重名 ambiguous_target，参数非法 invalid_params")
  func hostResolution() async {
    let fixture = AgentHostFixture(hostNames: ["web", "web", "db"])
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", host: "nope")).error?.code == .notFound)
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", host: "web")).error?.code == .ambiguousTarget)
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("a\u{1B}b", host: "db")).error?.code == .invalidParams)
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", host: "db", session: "")).error?.code == .invalidParams)
  }

  @Test("暂停的终端：agent_paused")
  func paused() async throws {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowSession
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    let terminal = try #require(fixture.service.registry.terminals.first)
    terminal.isPaused = true
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error?.code == .agentPaused)
  }

  @Test("调用 Pane 里的 agent 会并入有效会话键；Pane UUID 只带给呈现，不进会话键")
  func callerPaneExtendsKey() {
    let fixture = AgentHostFixture()
    let plain = fixture.service.resolveCaller(AgentHostCaller(session: "pane:w1:p1", client: "cli", callerPane: "w1:p1"))
    #expect(plain.key == "pane:w1:p1")
    #expect(plain.paneUUID == nil)
    var dependencies = fixture.service.dependencies
    let paneUUID = UUID()
    dependencies.resolvePane = { _ in ("w1:p1", paneUUID, .claudeCode, "abc") }
    let service = AgentHostService(dependencies: dependencies)
    let extended = service.resolveCaller(AgentHostCaller(session: "pane:w1:p1", callerPane: "w1:p1"))
    #expect(extended.key == "pane:w1:p1#\(AgentProvider.claudeCode.rawValue):abc")
    #expect(extended.displayName == AgentProvider.claudeCode.displayName)
    #expect(extended.paneUUID == paneUUID)
    #expect(!extended.key.contains(paneUUID.uuidString))
  }

  @Test("没有 caller_pane（Codex）时按自报的 agent 会话 ID 找 Pane；caller_pane 能解析时优先用它")
  func agentSessionFindsCallerPane() {
    let fixture = AgentHostFixture()
    var dependencies = fixture.service.dependencies
    let codexPane = UUID()
    let claudePane = UUID()
    dependencies.resolveAgentSessionPane = { session in
      session == "thread-1" ? ("w1:p3", codexPane, .codex, "thread-1") : nil
    }
    dependencies.resolvePane = { _ in ("w1:p1", claudePane, .claudeCode, "abc") }
    let service = AgentHostService(dependencies: dependencies)

    let codex = service.resolveCaller(AgentHostCaller(session: "mcp:x", client: "codex-mcp-client", agentSession: "thread-1"))
    #expect(codex.paneUUID == codexPane)
    #expect(codex.displayName == AgentProvider.codex.displayName)
    // 多个 Codex 会话可能共用一个 MCP 进程：会话键并入会话 ID 后彼此分开。
    #expect(codex.key == "mcp:x#\(AgentProvider.codex.rawValue):thread-1")

    let unknown = service.resolveCaller(AgentHostCaller(session: "mcp:x", agentSession: "other"))
    #expect(unknown.paneUUID == nil)
    #expect(unknown.key == "mcp:x")

    let both = service.resolveCaller(AgentHostCaller(session: "mcp:x", callerPane: "w1:p1", agentSession: "thread-1"))
    #expect(both.paneUUID == claudePane)
  }
}
