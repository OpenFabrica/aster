// agent 主机访问的审计记录：JSONL 一行一条，所有值都是字符串。
// 每条记录必须能独立回答：谁（账户 / agent 会话）、何时（带时区的 ISO 8601）、
// 对什么（主机 ID + 名称 + 目标）、从什么变成什么（字段级 before / after）。
// 绝不记录命令输出，命令本身先经 AgentHostCommandRedactor 脱敏。
import Foundation

/// 一条审计记录。
public struct AgentHostAuditRecord: Codable, Equatable, Sendable {
  /// 记录分类：执行、授权、设置分开存、分开查。
  public enum Category: String, Codable, CaseIterable, Sendable {
    case exec
    case grant
    case setting
  }

  /// 动作名。
  public enum Action: String, Codable, CaseIterable, Sendable {
    case execStarted = "exec.started"
    case execFinished = "exec.finished"
    case execPending = "exec.pending"
    case grantCreated = "grant.created"
    case grantRevoked = "grant.revoked"
    case grantDenied = "grant.denied"
    case grantExpired = "grant.expired"
    case grantInvalidated = "grant.invalidated"
    case settingChanged = "setting.changed"

    /// 动作所属分类。
    public var category: Category {
      switch self {
      case .execStarted, .execFinished, .execPending: .exec
      case .grantCreated, .grantRevoked, .grantDenied, .grantExpired, .grantInvalidated: .grant
      case .settingChanged: .setting
      }
    }
  }

  /// 操作者：agent（会话键 + 客户端 + Pane + provider）或本机用户（账户名唯一）。
  public struct Actor: Codable, Equatable, Sendable {
    public var kind: String
    public var client: String?
    public var session: String?
    public var pane: String?
    public var provider: String?
    public var agentSessionID: String?
    public var account: String?
    public var name: String?

    /// agent 操作者。
    public static func agent(
      session: String, client: String?, pane: String?, provider: String?, agentSessionID: String?
    ) -> Actor {
      Actor(
        kind: "agent", client: client, session: session, pane: pane, provider: provider,
        agentSessionID: agentSessionID)
    }

    /// 本机用户操作者；`account` 是 macOS 短账户名（唯一），`name` 是全名（可重名，仅展示）。
    public static func user(account: String, name: String?) -> Actor {
      Actor(kind: "user", account: account, name: name)
    }

    /// 系统自动动作（过期清理、主机删除连带作废）。
    public static let system = Actor(kind: "system")
  }

  /// 批准依据：用户当场批准，或命中已有授权。
  public struct Approver: Codable, Equatable, Sendable {
    public var kind: String
    public var account: String?
    public var scope: String?
    public var grantID: String?

    public static func user(account: String, scope: AgentHostGrantScope) -> Approver {
      Approver(kind: "user", account: account, scope: scope.rawValue)
    }

    public static func grant(_ grant: AgentHostGrant) -> Approver {
      Approver(kind: "grant", scope: grant.scope.rawValue, grantID: grant.grantID.uuidString)
    }
  }

  /// 被操作的主机。
  public struct HostReference: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var target: String

    public init(id: String, name: String, target: String) {
      self.id = id
      self.name = name
      self.target = target
    }
  }

  /// 执行结果；数值也存字符串，结构以后变了旧日志照样能解。
  public struct Outcome: Codable, Equatable, Sendable {
    public var status: String
    public var exitCode: String?
    public var durationMs: String
    public var outputBytes: String

    public init(status: HostExecStatus, exitCode: Int?, durationMs: Int, outputBytes: Int) {
      self.status = status.rawValue
      self.exitCode = exitCode.map(String.init)
      self.durationMs = String(durationMs)
      self.outputBytes = String(outputBytes)
    }
  }

  /// 字段级变化。新建 / 删除用固定占位串，与「从空改成有值」区分开。
  public struct Change: Codable, Equatable, Sendable {
    public static let created = "（新建）"
    public static let deleted = "（已删除）"

    public var field: String
    public var before: String
    public var after: String

    public init(field: String, before: String, after: String) {
      self.field = field
      self.before = before
      self.after = after
    }
  }

  public var id: String
  public var time: String
  public var category: Category
  public var action: Action
  public var actor: Actor
  public var approver: Approver?
  public var host: HostReference?
  public var commandID: String?
  public var terminalID: String?
  /// 已脱敏的命令。
  public var command: String?
  /// "true" 表示命令里有内容被脱敏替换。
  public var commandRedacted: String?
  public var reason: String?
  public var result: Outcome?
  public var changes: [Change]?

  public init(
    id: UUID = UUID(), time: Date, action: Action, actor: Actor, approver: Approver? = nil,
    host: HostReference? = nil, commandID: String? = nil, terminalID: String? = nil,
    command: String? = nil, reason: String? = nil, result: Outcome? = nil, changes: [Change]? = nil
  ) {
    self.id = id.uuidString
    self.time = Self.timestamp(time)
    self.category = action.category
    self.action = action
    self.actor = actor
    self.approver = approver
    self.host = host
    self.commandID = commandID
    self.terminalID = terminalID
    if let command {
      let redaction = AgentHostCommandRedactor.redact(command)
      self.command = redaction.text
      self.commandRedacted = redaction.redacted ? "true" : "false"
    }
    self.reason = reason
    self.result = result
    self.changes = changes
  }

  /// 带本地时区偏移的 ISO 8601（`2026-10-16T09:30:12+08:00`），人能直接读。
  public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  // MARK: - 授权快照

  /// 授权的完整快照字段（名称 → 值）。创建与删除都记全部字段，删除后靠它还原。
  public static func snapshotFields(of grant: AgentHostGrant, hostName: String) -> [(String, String)] {
    var fields: [(String, String)] = [
      ("grantID", grant.grantID.uuidString),
      ("scope", grant.scope.rawValue),
      ("hostID", grant.hostID.uuidString),
      ("hostName", hostName),
      ("targetFingerprint", grant.targetFingerprint),
      ("grantedAt", timestamp(grant.grantedAt)),
      ("grantedBy", grant.grantedBy),
    ]
    if let sessionKey = grant.sessionKey { fields.append(("session", sessionKey)) }
    // once 授权绑定的命令同样先脱敏：审计长期留存。
    if let command = grant.command { fields.append(("command", AgentHostCommandRedactor.redact(command).text)) }
    return fields
  }

  /// 新建快照：`before` 固定为「（新建）」。
  public static func creationChanges(of grant: AgentHostGrant, hostName: String) -> [Change] {
    snapshotFields(of: grant, hostName: hostName).map { Change(field: $0.0, before: Change.created, after: $0.1) }
  }

  /// 删除快照：`after` 固定为「（已删除）」。
  public static func deletionChanges(of grant: AgentHostGrant, hostName: String) -> [Change] {
    snapshotFields(of: grant, hostName: hostName).map { Change(field: $0.0, before: $0.1, after: Change.deleted) }
  }
}
