// 批准协调（相同请求合并、超时保留面板、迟到回答、取消）、审计日志落盘与授权持久化。
// 不同请求排队、「允许一次」与全局上限见 AgentHostApprovalQueueTests。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 不建窗口的批准面板：记录更新，测试直接调回答回调。
@MainActor
final class FakeApprovalPanel: AgentHostApprovalPanelHandling {
  let answer: @MainActor (AgentHostApprovalAnswer) -> Void
  private(set) var pendingCount = 1
  private(set) var closed = false
  init(answer: @escaping @MainActor (AgentHostApprovalAnswer) -> Void) { self.answer = answer }
  func update(_ request: AgentHostApprovalRequest, pendingCount: Int) { self.pendingCount = pendingCount }
  func close() { closed = true }
}

@Suite("agent 主机批准与存储")
@MainActor
struct AgentHostApprovalAndStorageTests {
  private func request(session: String = "s1", command: String = "ls") -> AgentHostApprovalRequest {
    AgentHostApprovalRequest(
      caller: AgentHostResolvedCaller(key: session, session: session), hostID: hostID, hostName: "prod",
      target: "u@h:22", reason: nil, command: command, targetFingerprint: "f")
  }
  private let hostID = UUID()

  @Test("同一会话、主机与命令的并发请求合并成一个面板；回答唤醒全部等待方")
  func coalesces() async throws {
    var panels: [FakeApprovalPanel] = []
    let coordinator = AgentHostApprovalCoordinator(makePanel: { _, answer in
      let panel = FakeApprovalPanel(answer: answer)
      panels.append(panel)
      return panel
    }, alert: { _ in })
    var answers: [(AgentHostApprovalAnswer, Bool)] = []
    coordinator.onAnswer = { _, answer, live in answers.append((answer, live)) }
    async let first = coordinator.requestApproval(request(command: "a"), timeout: .seconds(5))
    async let second = coordinator.requestApproval(request(command: "a"), timeout: .seconds(5))
    await pollUntil { panels.first?.pendingCount == 2 }
    #expect(panels.count == 1)
    #expect(panels[0].pendingCount == 2)
    panels[0].answer(.allowSession)
    #expect(try await first == .allowSession)
    #expect(try await second == .allowSession)
    #expect(panels[0].closed)
    #expect(answers.count == 1 && answers[0].1)
  }

  @Test("等待方超时返回 nil，面板保留；之后回答以 hadLiveWaiters=false 生效")
  func timeoutKeepsPanel() async throws {
    var panels: [FakeApprovalPanel] = []
    let coordinator = AgentHostApprovalCoordinator(makePanel: { _, answer in
      let panel = FakeApprovalPanel(answer: answer)
      panels.append(panel)
      return panel
    }, alert: { _ in })
    var late: Bool?
    coordinator.onAnswer = { _, _, live in late = !live }
    #expect(try await coordinator.requestApproval(request(), timeout: .milliseconds(30)) == nil)
    #expect(panels.first?.closed == false)
    panels[0].answer(.allowOnce)
    #expect(late == true)
    // 新请求得到新面板。
    _ = try await coordinator.requestApproval(request(), timeout: .milliseconds(10))
    #expect(panels.count == 2)
  }

  @Test("被取消的等待方立即返回；dismissAll 关闭面板并唤醒等待方")
  func cancellationAndDismiss() async throws {
    let coordinator = AgentHostApprovalCoordinator(makePanel: { _, answer in FakeApprovalPanel(answer: answer) }, alert: { _ in })
    let task = Task { try await coordinator.requestApproval(request(), timeout: .seconds(30)) }
    await pollUntil { coordinator.pendingRequestCount == 1 }
    task.cancel()
    #expect(try await task.value == nil)
    let waiting = Task { try await coordinator.requestApproval(request(session: "s2"), timeout: .seconds(30)) }
    await pollUntil { coordinator.pendingRequestCount == 2 }
    coordinator.dismissAll(hostID: hostID)
    #expect(try await waiting.value == nil)
    #expect(coordinator.pendingRequestCount == 0)
  }

  @Test("审计日志：按月 JSONL，目录 0700、文件 0600，新到旧分页")
  func auditLogFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aster-audit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = AgentHostAuditLog(directory: directory)
    for index in 0..<5 {
      log.append(
        AgentHostAuditRecord(
          time: Date(), action: .settingChanged, actor: .user(account: "mike", name: nil),
          changes: [.init(field: "n", before: "\(index)", after: "\(index + 1)")]))
    }
    await log.flush()
    let file = directory.appendingPathComponent(AgentHostAuditLog.fileName(for: Date()))
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    #expect(fileMode == 0o600)
    #expect(directoryMode == 0o700)
    let first = await log.page(before: nil, limit: 2)
    #expect(first.records.map { $0.changes?.first?.before } == ["4", "3"])
    let second = await log.page(before: first.nextBefore, limit: 2)
    #expect(second.records.map { $0.changes?.first?.before } == ["2", "1"])
    let last = await log.page(before: second.nextBefore, limit: 2)
    #expect(last.records.count == 1)
    #expect(last.nextBefore == nil)
  }

  @Test("always 授权写进持久层并在新实例里读回；撤销同步删除；变化都有审计")
  func grantPersistence() async throws {
    let persistence = InMemoryAgentHostGrantPersistence()
    let audit = MemoryAuditLog()
    let store = AgentHostGrantStore(persistence: persistence, audit: audit, hostLookup: { _ in nil })
    await store.loadIfNeeded()
    let grant = AgentHostGrant(
      hostID: hostID, scope: .always, sessionKey: nil, targetFingerprint: "f", grantedAt: Date(), grantedBy: "mike")
    store.add(grant, by: AgentHostLocalUser(account: "mike", name: "Mike"))
    store.add(
      AgentHostGrant(hostID: hostID, scope: .session, sessionKey: "s", targetFingerprint: "f", grantedAt: Date(), grantedBy: "mike"),
      by: AgentHostLocalUser(account: "mike", name: "Mike"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(try persistence.load().map(\.grantID) == [grant.grantID])
    let reloaded = AgentHostGrantStore(persistence: persistence, audit: audit, hostLookup: { _ in nil })
    await reloaded.loadIfNeeded()
    #expect(reloaded.alwaysGrantedHostIDs(currentFingerprints: [hostID: "f"]) == [hostID])
    // 目标已变的主机不再报 always。
    #expect(reloaded.alwaysGrantedHostIDs(currentFingerprints: [hostID: "moved"]).isEmpty)
    reloaded.removeGrants(forHost: hostID, hostName: "prod")
    try await Task.sleep(for: .milliseconds(100))
    #expect(try persistence.load().isEmpty)
    #expect(audit.actions == [.grantCreated, .grantCreated, .grantInvalidated])
    #expect(audit.records.last?.actor.kind == "system")
  }

  @Test("钥匙串条目 ACL 不可信：当作没有 always 授权，写作废审计，不删条目")
  func untrustedKeychainItemIgnored() async {
    let audit = MemoryAuditLog()
    let store = AgentHostGrantStore(persistence: UntrustedGrantPersistence(), audit: audit, hostLookup: { _ in nil })
    await store.loadIfNeeded()
    #expect(store.grants.isEmpty)
    #expect(audit.actions == [.grantInvalidated])
    #expect(audit.records.first?.actor.kind == "system")
    #expect(audit.records.first?.changes?.first?.after == "ignored")
  }
}

/// 模拟被预埋的钥匙串条目：读取总是报 ACL 不可信。
private struct UntrustedGrantPersistence: AgentHostGrantPersisting {
  func load() throws -> [AgentHostGrant] { throw AgentHostGrantKeychainError.untrustedAccess("decrypt 信任任何 App") }
  func save(_ grants: [AgentHostGrant]) throws {}
}
