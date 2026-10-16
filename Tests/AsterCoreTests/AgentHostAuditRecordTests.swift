import Foundation
import Testing

@testable import AsterCore

@Suite("agent 主机审计记录")
struct AgentHostAuditRecordTests {
  private let host = AgentHostAuditRecord.HostReference(id: UUID().uuidString, name: "prod-db", target: "deploy@10.0.0.5:22")
  private let time = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("执行记录：谁、何时、对哪台主机、命令已脱敏、结果全是字符串、不含输出")
  func execRecord() throws {
    let record = AgentHostAuditRecord(
      time: time, action: .execFinished,
      actor: .agent(session: "mcp:1#claudeCode:abc", client: "claude-code", pane: "w1:p2", provider: "claudeCode", agentSessionID: "abc"),
      approver: .user(account: "mike", scope: .session), host: host, commandID: "c-1", terminalID: "t-1",
      command: "mysql -pSECRET -e 'select 1'", reason: "check db",
      result: .init(status: .completed, exitCode: 0, durationMs: 1234, outputBytes: 42))
    #expect(record.category == .exec)
    #expect(record.command?.contains("SECRET") == false)
    #expect(record.commandRedacted == "true")
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    #expect(json.contains(#""exitCode":"0""#))
    #expect(json.contains(#""durationMs":"1234""#))
    #expect(json.contains(#""account":"mike""#))
    #expect(!json.contains("SECRET"))
    let decoded = try JSONDecoder().decode(AgentHostAuditRecord.self, from: Data(json.utf8))
    #expect(decoded == record)
  }

  @Test("时间带时区偏移，人能直接读")
  func timestampHasOffset() {
    let text = AgentHostAuditRecord.timestamp(time, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    #expect(text == "2027-01-15T16:00:00+08:00")
  }

  @Test("授权新建 / 删除带完整快照，占位串在固定一侧")
  func grantSnapshots() {
    let grant = AgentHostGrant(
      hostID: UUID(), scope: .session, sessionKey: "cli:default", targetFingerprint: "h|u|22|",
      grantedAt: time, grantedBy: "mike")
    let created = AgentHostAuditRecord.creationChanges(of: grant, hostName: "prod-db")
    let deleted = AgentHostAuditRecord.deletionChanges(of: grant, hostName: "prod-db")
    let fields = ["grantID", "scope", "hostID", "hostName", "targetFingerprint", "grantedAt", "grantedBy", "session"]
    #expect(created.map(\.field) == fields)
    #expect(deleted.map(\.field) == fields)
    #expect(created.allSatisfy { $0.before == AgentHostAuditRecord.Change.created && $0.after != AgentHostAuditRecord.Change.created })
    #expect(deleted.allSatisfy { $0.after == AgentHostAuditRecord.Change.deleted })
    #expect(created.first { $0.field == "grantedBy" }?.after == "mike")
    #expect(deleted.first { $0.field == "scope" }?.before == "session")
  }

  @Test("动作归入正确分类")
  func categories() {
    #expect(AgentHostAuditRecord.Action.execPending.category == .exec)
    #expect(AgentHostAuditRecord.Action.grantDenied.category == .grant)
    #expect(AgentHostAuditRecord.Action.settingChanged.category == .setting)
    #expect(AgentHostAuditRecord.Action.allCases.allSatisfy { $0.rawValue.hasPrefix($0.category.rawValue + ".") })
  }
}
