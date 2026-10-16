// agent 主机授权的权威存储：once / session 只在内存，always 同步到钥匙串。
// 每一次授权的新建、撤销、拒绝、过期与作废都写审计（新建 / 删除带完整快照）。
import AsterCore
import Foundation

/// 本机用户身份：账户名唯一，全名只用于展示。
struct AgentHostLocalUser: Equatable, Sendable {
  var account: String
  var name: String

  static var current: AgentHostLocalUser { AgentHostLocalUser(account: NSUserName(), name: NSFullUserName()) }
}

/// 授权存储。
@MainActor
final class AgentHostGrantStore {
  /// 主机的展示信息（名称、`user@host:port`）；主机已删除时为 nil。
  typealias HostLookup = @MainActor (UUID) -> AgentHostAuditRecord.HostReference?

  private(set) var book = AgentHostGrantBook()
  private let persistence: any AgentHostGrantPersisting
  private let audit: any AgentHostAuditWriting
  private let hostLookup: HostLookup
  private let now: () -> Date
  private var loadTask: Task<Void, Never>?
  /// 写钥匙串的串行队列：保证后写的快照不会被先写的覆盖。
  private let saveQueue = DispatchQueue(label: "io.aster.agent-hosts.grants", qos: .utility)
  /// 授权集合变化（设置页刷新）。
  var onChange: (() -> Void)?

  init(
    persistence: any AgentHostGrantPersisting, audit: any AgentHostAuditWriting,
    hostLookup: @escaping HostLookup, now: @escaping () -> Date = Date.init
  ) {
    self.persistence = persistence
    self.audit = audit
    self.hostLookup = hostLookup
    self.now = now
  }

  var grants: [AgentHostGrant] { book.grants }

  /// 有 always 授权的主机（`host.list` 的 `agentAccess` 字段）。
  var alwaysGrantedHostIDs: Set<UUID> { Set(book.grants.filter { $0.scope == .always }.map(\.hostID)) }

  /// 在后台读一次钥匙串；读失败按「没有 always 授权」处理（只会多问一次，不会多放行）。
  func loadIfNeeded() async {
    if loadTask == nil {
      let persistence = persistence
      loadTask = Task { @MainActor [weak self] in
        let loaded = await Task.detached(priority: .utility) { () -> Result<[AgentHostGrant], any Error> in
          Result { try persistence.load() }
        }.value
        guard let self else { return }
        switch loaded {
        case .success(let grants):
          for grant in grants where grant.scope == .always { self.book.add(grant) }
          self.onChange?()
        case .failure(let error):
          DiagnosticsCenter.shared.record(
            "agent_hosts.grants_load_failed", level: .error, category: .storage, error: error)
        }
      }
    }
    await loadTask?.value
  }

  /// 判断一次执行能否放行；作废与过期的授权顺带写审计并落盘。
  func evaluate(hostID: UUID, sessionKey: String, fingerprint: String) async -> AgentHostGrantBook.Decision {
    await loadIfNeeded()
    let evaluation = book.evaluate(hostID: hostID, sessionKey: sessionKey, fingerprint: fingerprint, now: now())
    for grant in evaluation.invalidated {
      record(.grantInvalidated, grant: grant, actor: .system, changes: deletionChanges(grant))
    }
    for grant in evaluation.expired {
      record(.grantExpired, grant: grant, actor: .system, changes: deletionChanges(grant))
    }
    if !evaluation.invalidated.isEmpty || !evaluation.expired.isEmpty { changed(touchesAlways: true) }
    return evaluation.decision
  }

  /// 记一条新授权（用户在批准面板里点的）。
  func add(_ grant: AgentHostGrant, by user: AgentHostLocalUser) {
    if let replaced = book.add(grant) {
      record(.grantRevoked, grant: replaced, actor: .user(account: user.account, name: user.name),
        changes: deletionChanges(replaced))
    }
    record(.grantCreated, grant: grant, actor: .user(account: user.account, name: user.name),
      changes: AgentHostAuditRecord.creationChanges(of: grant, hostName: hostName(grant.hostID)))
    changed(touchesAlways: grant.scope == .always)
  }

  /// 用户拒绝：开始 10 分钟冷却，写审计。
  func recordDenial(sessionKey: String, hostID: UUID, by user: AgentHostLocalUser) {
    let time = now()
    book.recordDenial(sessionKey: sessionKey, hostID: hostID, now: time)
    let until = AgentHostAuditRecord.timestamp(time.addingTimeInterval(AgentHostGrantBook.denialCooldown))
    audit.append(
      AgentHostAuditRecord(
        time: time, action: .grantDenied, actor: .user(account: user.account, name: user.name),
        host: hostLookup(hostID) ?? missingHost(hostID),
        changes: [
          .init(field: "session", before: AgentHostAuditRecord.Change.created, after: sessionKey),
          .init(field: "deniedUntil", before: AgentHostAuditRecord.Change.created, after: until),
        ]))
    onChange?()
  }

  /// 撤销一条授权（设置页）。不存在返回 false。
  @discardableResult
  func revoke(grantID: UUID, by user: AgentHostLocalUser) -> Bool {
    guard let grant = book.revoke(grantID: grantID) else { return false }
    record(.grantRevoked, grant: grant, actor: .user(account: user.account, name: user.name),
      changes: deletionChanges(grant))
    changed(touchesAlways: grant.scope == .always)
    return true
  }

  /// 撤销全部授权（设置页「全部撤销」）；返回撤销条数。
  @discardableResult
  func revokeAll(by user: AgentHostLocalUser) -> Int {
    let removed = book.revokeAll()
    for grant in removed {
      record(.grantRevoked, grant: grant, actor: .user(account: user.account, name: user.name),
        changes: deletionChanges(grant))
    }
    if !removed.isEmpty { changed(touchesAlways: true) }
    return removed.count
  }

  /// 主机被删除：它的全部授权随之作废。
  func removeGrants(forHost hostID: UUID, hostName: String) {
    let removed = book.revokeAll(hostID: hostID)
    for grant in removed {
      record(.grantInvalidated, grant: grant, actor: .system,
        changes: AgentHostAuditRecord.deletionChanges(of: grant, hostName: hostName))
    }
    if !removed.isEmpty { changed(touchesAlways: true) }
  }

  // MARK: - 内部

  private func hostName(_ hostID: UUID) -> String {
    hostLookup(hostID)?.name ?? "（主机已删除）"
  }

  private func missingHost(_ hostID: UUID) -> AgentHostAuditRecord.HostReference {
    .init(id: hostID.uuidString, name: "（主机已删除）", target: "")
  }

  private func deletionChanges(_ grant: AgentHostGrant) -> [AgentHostAuditRecord.Change] {
    AgentHostAuditRecord.deletionChanges(of: grant, hostName: hostName(grant.hostID))
  }

  /// 写一条授权类审计。
  private func record(
    _ action: AgentHostAuditRecord.Action, grant: AgentHostGrant, actor: AgentHostAuditRecord.Actor,
    changes: [AgentHostAuditRecord.Change]
  ) {
    audit.append(
      AgentHostAuditRecord(
        time: now(), action: action, actor: actor,
        host: hostLookup(grant.hostID) ?? missingHost(grant.hostID), changes: changes))
  }

  /// 通知刷新；always 集合可能变化时把快照写进钥匙串（后台串行）。
  private func changed(touchesAlways: Bool) {
    onChange?()
    guard touchesAlways else { return }
    let snapshot = book.grants.filter { $0.scope == .always }
    let persistence = persistence
    saveQueue.async {
      do {
        try persistence.save(snapshot)
      } catch {
        Task { @MainActor in
          DiagnosticsCenter.shared.record(
            "agent_hosts.grants_save_failed", level: .error, category: .storage, error: error)
        }
      }
    }
  }
}
