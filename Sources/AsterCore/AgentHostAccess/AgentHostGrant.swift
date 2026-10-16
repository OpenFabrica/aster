// agent 主机访问的授权模型：授权条目、目标指纹与授权簿（值类型，纯逻辑）。
// 存储（内存 / 钥匙串）与批准界面在 App 层；这里只回答「这次能不能放行」。
import Foundation

/// 授权范围。
public enum AgentHostGrantScope: String, Codable, CaseIterable, Sendable {
  /// 只放行一次。批准时原请求已超时，才会作为「一次性授权」留在簿里，只给同一条命令的下一次执行消耗。
  case once
  /// 本 agent 会话内有效；退出 App 或 12 小时不活动即失效。
  case session
  /// 一直允许这台主机（任意会话），存钥匙串，可在设置里撤销。
  case always
}

/// 一条授权。
public struct AgentHostGrant: Codable, Equatable, Sendable, Identifiable {
  public var grantID: UUID
  public var hostID: UUID
  public var scope: AgentHostGrantScope
  /// once / session 授权所属的有效会话键；always 为 nil（对所有会话生效）。
  public var sessionKey: String?
  /// 批准时的连接目标指纹；主机地址、用户、端口或跳板变了就作废，必须重新批准。
  public var targetFingerprint: String
  public var grantedAt: Date
  /// 批准人的 macOS 账户名。
  public var grantedBy: String
  /// 最近一次放行时间；session 授权按它判断 12 小时不活动。
  public var lastUsedAt: Date?
  /// once 授权批准的那条命令（nil 表示 `host.open`）；只放行内容完全相同的请求。
  /// session / always 不绑定命令，恒为 nil。只有 always 会落钥匙串，旧数据没有这个键也能解码。
  public var command: String?

  public var id: UUID { grantID }

  public init(
    grantID: UUID = UUID(), hostID: UUID, scope: AgentHostGrantScope, sessionKey: String?,
    targetFingerprint: String, grantedAt: Date, grantedBy: String, lastUsedAt: Date? = nil, command: String? = nil
  ) {
    self.grantID = grantID
    self.hostID = hostID
    self.scope = scope
    self.sessionKey = scope == .always ? nil : sessionKey
    self.targetFingerprint = targetFingerprint
    self.grantedAt = grantedAt
    self.grantedBy = grantedBy
    self.lastUsedAt = lastUsedAt
    self.command = scope == .once ? command : nil
  }
}

/// 连接目标指纹：`host|user|port|跳板链`。批准针对的是「连到哪里、以谁的身份」，
/// 只改主机名称不影响；改地址、用户、端口或跳板都要重新问。
public enum AgentHostTargetFingerprint {
  /// 跳板链按从近到远排列，每一跳写成 `user@host:port`。
  public static func make(host: String, user: String, port: Int, jumpChain: [String]) -> String {
    [host.lowercased(), user, String(port), jumpChain.joined(separator: ",")].joined(separator: "|")
  }
}

/// 授权簿：判断、记录、撤销与过期清理。值类型，调用方负责持久化 always 部分。
public struct AgentHostGrantBook: Equatable, Sendable {
  /// 拒绝后的冷却期：这台主机 10 分钟内对所有会话直接 `approval_denied`，不再弹窗。
  /// 按主机而不按会话：会话键由调用方自报，换个 session 名就能绕开按会话的冷却继续刷面板。
  public static let denialCooldown: TimeInterval = 10 * 60
  /// session 授权的不活动上限。
  public static let sessionInactivityLimit: TimeInterval = 12 * 60 * 60
  /// 一次性授权（批准时原请求已超时）的有效期。
  public static let pendingOnceLifetime: TimeInterval = 5 * 60

  /// 一次拒绝记录。`sessionKey` 只说明是谁的请求被拒，冷却对这台主机的所有会话生效。
  public struct Denial: Equatable, Sendable {
    public var sessionKey: String
    public var hostID: UUID
    public var until: Date
  }

  /// 判断结果。
  public enum Decision: Equatable, Sendable {
    case allowed(AgentHostGrant)
    case deniedRecently(until: Date)
    case needsApproval
  }

  /// 一次判断的完整产物：除了结论，还带出被作废 / 过期的授权，供调用方写审计。
  public struct Evaluation: Equatable, Sendable {
    public var decision: Decision
    /// 指纹不符而作废的授权。
    public var invalidated: [AgentHostGrant]
    /// 到期清理掉的授权。
    public var expired: [AgentHostGrant]
  }

  public private(set) var grants: [AgentHostGrant]
  public private(set) var denials: [Denial] = []

  public init(grants: [AgentHostGrant] = []) { self.grants = grants }

  /// 判断一次执行能否放行。`command` 为 nil 表示 `host.open`。
  ///
  /// 顺序：先清理过期，再作废指纹不符的授权；然后 always → session → 拒绝冷却 → once。
  /// 授权先于拒绝：用户后来明确「一直允许」时，不该被更早的拒绝挡住。
  /// once 授权只匹配同一条命令，放行时被消耗；session 授权刷新最近使用时间。
  public mutating func evaluate(
    hostID: UUID, sessionKey: String, fingerprint: String, command: String?, now: Date
  ) -> Evaluation {
    let expired = prune(now: now)
    let invalidated = invalidate(hostID: hostID, keeping: fingerprint)

    if let grant = grants.first(where: { $0.hostID == hostID && $0.scope == .always }) {
      return Evaluation(decision: .allowed(grant), invalidated: invalidated, expired: expired)
    }
    if let index = grants.firstIndex(where: {
      $0.hostID == hostID && $0.scope == .session && $0.sessionKey == sessionKey
    }) {
      grants[index].lastUsedAt = now
      return Evaluation(decision: .allowed(grants[index]), invalidated: invalidated, expired: expired)
    }
    if let denial = denials.first(where: { $0.hostID == hostID }) {
      return Evaluation(decision: .deniedRecently(until: denial.until), invalidated: invalidated, expired: expired)
    }
    if let index = grants.firstIndex(where: {
      $0.hostID == hostID && $0.scope == .once && $0.sessionKey == sessionKey && $0.command == command
    }) {
      let grant = grants.remove(at: index)
      return Evaluation(decision: .allowed(grant), invalidated: invalidated, expired: expired)
    }
    return Evaluation(decision: .needsApproval, invalidated: invalidated, expired: expired)
  }

  /// 记一条授权。同一（范围、主机、会话）只保留最新一条，返回被替换的旧条目。
  @discardableResult
  public mutating func add(_ grant: AgentHostGrant) -> AgentHostGrant? {
    var replaced: AgentHostGrant?
    if let index = grants.firstIndex(where: {
      $0.scope == grant.scope && $0.hostID == grant.hostID && $0.sessionKey == grant.sessionKey
    }) {
      replaced = grants.remove(at: index)
    }
    grants.append(grant)
    // 新的授权意味着用户对这台主机改了主意；冷却按主机计，随之整体解除。
    denials.removeAll { $0.hostID == grant.hostID }
    return replaced
  }

  /// 退还一条被消耗但没用上的 once 授权（命令最终没敲进终端）。
  /// 原样放回、不动拒绝冷却：它不是用户新的决定，只是撤销一次未生效的消耗。
  public mutating func restore(_ grant: AgentHostGrant) {
    guard grant.scope == .once, !grants.contains(where: { $0.grantID == grant.grantID }) else { return }
    grants.append(grant)
  }

  /// 记一次拒绝，开始这台主机的冷却（覆盖之前的冷却）。
  public mutating func recordDenial(sessionKey: String, hostID: UUID, now: Date) {
    denials.removeAll { $0.hostID == hostID }
    denials.append(Denial(sessionKey: sessionKey, hostID: hostID, until: now.addingTimeInterval(Self.denialCooldown)))
  }

  /// 作废某台主机上指纹不是 `fingerprint` 的授权（nil 表示主机已不存在，全部作废）；返回被作废的条目。
  @discardableResult
  public mutating func invalidate(hostID: UUID, keeping fingerprint: String?) -> [AgentHostGrant] {
    let stale: (AgentHostGrant) -> Bool = { $0.hostID == hostID && $0.targetFingerprint != fingerprint }
    let removed = grants.filter(stale)
    grants.removeAll(where: stale)
    return removed
  }

  /// 撤销一条授权；不存在返回 nil。
  @discardableResult
  public mutating func revoke(grantID: UUID) -> AgentHostGrant? {
    guard let index = grants.firstIndex(where: { $0.grantID == grantID }) else { return nil }
    return grants.remove(at: index)
  }

  /// 撤销全部授权，或只撤销某台主机的；返回被撤销的条目。
  @discardableResult
  public mutating func revokeAll(hostID: UUID? = nil) -> [AgentHostGrant] {
    let removed = grants.filter { hostID == nil || $0.hostID == hostID }
    grants.removeAll { hostID == nil || $0.hostID == hostID }
    if let hostID { denials.removeAll { $0.hostID == hostID } }
    return removed
  }

  /// 清理过期的 once / session 授权与拒绝冷却；返回清理掉的授权。
  @discardableResult
  public mutating func prune(now: Date) -> [AgentHostGrant] {
    let expired = grants.filter { isExpired($0, now: now) }
    let expiredIDs = Set(expired.map(\.grantID))
    grants.removeAll { expiredIDs.contains($0.grantID) }
    denials.removeAll { $0.until <= now }
    return expired
  }

  /// once 超过 5 分钟、session 超过 12 小时没用即过期；always 不过期。
  private func isExpired(_ grant: AgentHostGrant, now: Date) -> Bool {
    switch grant.scope {
    case .once: now.timeIntervalSince(grant.grantedAt) > Self.pendingOnceLifetime
    case .session: now.timeIntervalSince(grant.lastUsedAt ?? grant.grantedAt) > Self.sessionInactivityLimit
    case .always: false
    }
  }
}
