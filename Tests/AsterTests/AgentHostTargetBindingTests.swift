// 批准与目标指纹的绑定、once 授权的消耗与退还、按主机的拒绝冷却、批准后的连接期限。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Suite("agent 远程执行：目标绑定与授权消耗")
@MainActor
struct AgentHostTargetBindingTests {
  /// 夹具里唯一一台已保存主机（第 0 项是默认项）。
  private func hostID(_ fixture: AgentHostFixture) -> UUID { fixture.surfaces.hosts[1].id }

  /// 直接往授权簿里放一条绑定命令的 once 授权（指纹取当前目标）。
  private func addOnce(_ fixture: AgentHostFixture, command: String) throws -> AgentHostGrant {
    let id = hostID(fixture)
    let grant = AgentHostGrant(
      hostID: id, scope: .once, sessionKey: "s1",
      targetFingerprint: try #require(fixture.service.currentFingerprints()[id]), grantedAt: Date(),
      grantedBy: "tester", command: command)
    fixture.service.grants.add(grant, by: AgentHostLocalUser(account: "tester", name: "T"))
    return grant
  }

  @Test("等批准期间主机地址被改：批准作废（host_not_ready + grant.invalidated），不建终端")
  func targetChangedDuringApproval() async {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowSession
    fixture.approvals.beforeAnswer = { fixture.surfaces.hosts[1].host = "evil.example.com" }
    let response = await fixture.call("host.exec", AgentHostFixture.exec("uptime"))
    #expect(response.error?.code == .hostNotReady)
    #expect(fixture.audit.actions == [.grantCreated, .grantInvalidated])
    #expect(fixture.service.grants.grants.isEmpty)
    #expect(fixture.service.registry.terminals.isEmpty)
    #expect(fixture.service.alwaysGrantedHostIDs().isEmpty)
  }

  @Test("当场「允许一次」后目标变了：同样作废并记一条 once 的 grant.invalidated")
  func allowOnceTargetChanged() async {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowOnce
    fixture.approvals.beforeAnswer = { fixture.surfaces.hosts[1].port = 2222 }
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("uptime")).error?.code == .hostNotReady)
    #expect(fixture.audit.actions == [.grantInvalidated])
    #expect(fixture.audit.records.first?.changes?.contains { $0.field == "scope" && $0.before == "once" } == true)
  }

  @Test("迟到的批准绑定请求发起时的指纹；目标已变时撤掉挂起面板，旧授权不放行")
  func lateAnswerBindsRequestFingerprint() async throws {
    let fixture = AgentHostFixture()
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", timeoutMs: 300)).error?.code == .approvalPending)
    let request = try #require(fixture.approvals.requests.first)
    fixture.service.handleHostsChanged()
    #expect(fixture.approvals.dismissed.isEmpty)
    fixture.surfaces.hosts[1].user = "root"
    fixture.service.handleHostsChanged()
    #expect(fixture.approvals.dismissed == [request])
    fixture.approvals.answerLate(request, .allowAlways)
    #expect(fixture.service.grants.grants.first?.targetFingerprint == request.targetFingerprint)
    #expect(fixture.service.alwaysGrantedHostIDs().isEmpty)
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", timeoutMs: 300)).error?.code == .approvalPending)
    #expect(fixture.audit.actions.contains(.grantInvalidated))
  }

  @Test("暂停时不消耗 once 授权；恢复后同一条命令照常消耗")
  func pauseKeepsOnceGrant() async throws {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowOnce
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    fixture.approvals.nextAnswer = nil
    let grant = try addOnce(fixture, command: "ls")
    let terminal = try #require(fixture.service.registry.terminals.first)
    terminal.isPaused = true
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls")).error?.code == .agentPaused)
    #expect(fixture.service.grants.grants.map(\.grantID) == [grant.grantID])
    terminal.isPaused = false
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls")).error == nil)
    #expect(fixture.service.grants.grants.isEmpty)
  }

  @Test("命令没敲进终端：消耗的 once 授权原样退还；当场「允许一次」落成一次性授权")
  func refundsOnceWhenNotTyped() async throws {
    let fixture = AgentHostFixture { $0.isNativeSSHClient = nil }
    let grant = try addOnce(fixture, command: "ls")
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", timeoutMs: 300)).error?.code == .hostNotReady)
    #expect(fixture.service.grants.grants == [grant])

    let other = AgentHostFixture { $0.isNativeSSHClient = nil }
    other.approvals.nextAnswer = .allowOnce
    #expect(await other.call("host.exec", AgentHostFixture.exec("df -h", timeoutMs: 300)).error?.code == .hostNotReady)
    #expect(other.service.grants.grants.map(\.scope) == [.once])
    #expect(other.service.grants.grants.first?.command == "df -h")
  }

  @Test("拒绝冷却按主机：换一个会话键也直接 approval_denied，不再弹窗")
  func denialAppliesToAllSessions() async {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .deny
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls")).error?.code == .approvalDenied)
    fixture.approvals.nextAnswer = .allowAlways
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", session: "fresh")).error?.code == .approvalDenied)
    #expect(fixture.approvals.requests.count == 1)
  }

  @Test("批准后的期限：剩余不足 30 秒时补足，但最多比原期限多 10 秒，且不超过请求超时")
  func postApprovalDeadline() {
    let now = ContinuousClock.now
    let late = AgentHostService.postApprovalDeadline(original: now + .seconds(2), timeout: .seconds(120), now: now)
    #expect(late == now + .seconds(12))
    let plenty = AgentHostService.postApprovalDeadline(original: now + .seconds(60), timeout: .seconds(120), now: now)
    #expect(plenty == now + .seconds(60))
    let short = AgentHostService.postApprovalDeadline(original: now + .seconds(1), timeout: .seconds(5), now: now)
    #expect(short == now + .seconds(5))
  }
}
