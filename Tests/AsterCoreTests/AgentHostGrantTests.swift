import Foundation
import Testing

@testable import AsterCore

private let host = UUID()
private let fingerprint = AgentHostTargetFingerprint.make(host: "10.0.0.5", user: "deploy", port: 22, jumpChain: [])
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// 造一条授权。
private func grant(_ scope: AgentHostGrantScope, session: String? = "s1", at time: Date = start) -> AgentHostGrant {
  AgentHostGrant(
    hostID: host, scope: scope, sessionKey: session, targetFingerprint: fingerprint, grantedAt: time,
    grantedBy: "mike", lastUsedAt: time)
}

@Suite("agent 主机授权簿")
struct AgentHostGrantTests {
  @Test("没有授权需要批准；always 对任意会话生效；session 只对本会话")
  func scopes() {
    var book = AgentHostGrantBook()
    #expect(book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: start).decision == .needsApproval)
    book.add(grant(.session))
    guard case .allowed = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: start).decision else {
      Issue.record("session 授权应放行本会话")
      return
    }
    #expect(book.evaluate(hostID: host, sessionKey: "s2", fingerprint: fingerprint, now: start).decision == .needsApproval)
    book.add(grant(.always, session: "ignored"))
    #expect(book.grants.first { $0.scope == .always }?.sessionKey == nil)
    guard case .allowed(let always) = book.evaluate(hostID: host, sessionKey: "s2", fingerprint: fingerprint, now: start).decision
    else {
      Issue.record("always 授权应放行任意会话")
      return
    }
    #expect(always.scope == .always)
  }

  @Test("一次性授权被下一次执行消耗，5 分钟后过期")
  func onceConsumedAndExpires() {
    var book = AgentHostGrantBook()
    book.add(grant(.once))
    guard case .allowed(let used) = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: start).decision
    else {
      Issue.record("一次性授权应放行一次")
      return
    }
    #expect(used.scope == .once)
    #expect(book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: start).decision == .needsApproval)
    book.add(grant(.once))
    let later = start.addingTimeInterval(AgentHostGrantBook.pendingOnceLifetime + 1)
    let evaluation = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: later)
    #expect(evaluation.decision == .needsApproval)
    #expect(evaluation.expired.map(\.scope) == [.once])
  }

  @Test("session 授权 12 小时不活动过期，使用会续期")
  func sessionInactivity() {
    var book = AgentHostGrantBook()
    book.add(grant(.session))
    let almost = start.addingTimeInterval(AgentHostGrantBook.sessionInactivityLimit - 10)
    _ = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: almost)
    let renewed = almost.addingTimeInterval(AgentHostGrantBook.sessionInactivityLimit - 10)
    guard case .allowed = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: renewed).decision else {
      Issue.record("使用后应续期")
      return
    }
    let expired = renewed.addingTimeInterval(AgentHostGrantBook.sessionInactivityLimit + 1)
    #expect(book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: expired).decision == .needsApproval)
  }

  @Test("目标指纹变了（改地址、用户、端口、跳板）授权作废")
  func fingerprintChangeInvalidates() {
    var book = AgentHostGrantBook()
    book.add(grant(.always))
    let moved = AgentHostTargetFingerprint.make(host: "10.0.0.6", user: "deploy", port: 22, jumpChain: [])
    let evaluation = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: moved, now: start)
    #expect(evaluation.decision == .needsApproval)
    #expect(evaluation.invalidated.count == 1)
    #expect(book.grants.isEmpty)
    #expect(
      AgentHostTargetFingerprint.make(host: "H", user: "u", port: 22, jumpChain: ["a@j:22"])
        != AgentHostTargetFingerprint.make(host: "h", user: "u", port: 22, jumpChain: []))
  }

  @Test("拒绝冷却 10 分钟；新授权解除冷却；授权优先于其它会话的拒绝")
  func denialCooldown() {
    var book = AgentHostGrantBook()
    book.recordDenial(sessionKey: "s1", hostID: host, now: start)
    let soon = start.addingTimeInterval(60)
    #expect(book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: soon).decision
      == .deniedRecently(until: start.addingTimeInterval(AgentHostGrantBook.denialCooldown)))
    #expect(book.evaluate(hostID: host, sessionKey: "s2", fingerprint: fingerprint, now: soon).decision == .needsApproval)
    let after = start.addingTimeInterval(AgentHostGrantBook.denialCooldown + 1)
    #expect(book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: after).decision == .needsApproval)
    book.recordDenial(sessionKey: "s1", hostID: host, now: after)
    book.add(grant(.session, at: after))
    guard case .allowed = book.evaluate(hostID: host, sessionKey: "s1", fingerprint: fingerprint, now: after).decision else {
      Issue.record("新授权应解除冷却")
      return
    }
  }

  @Test("撤销单条、按主机、全部；同范围重复授权替换旧条目")
  func revoke() {
    var book = AgentHostGrantBook()
    let first = grant(.always)
    book.add(first)
    let replaced = book.add(grant(.always))
    #expect(replaced == first)
    #expect(book.grants.count == 1)
    book.add(grant(.session))
    #expect(book.revoke(grantID: UUID()) == nil)
    #expect(book.revoke(grantID: book.grants[0].grantID) != nil)
    #expect(book.revokeAll(hostID: UUID()).isEmpty)
    #expect(book.revokeAll(hostID: host).count == 1)
    #expect(book.grants.isEmpty)
  }
}
