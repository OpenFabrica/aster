// 设置页「主机 → Agent 访问」的桥接：快照（开关、授权、agent 终端、MCP 安装）与 `hosts.*Agent*` 动作。
// 真值在 AgentHostRuntime（开关在 AppPreferences，授权在 AgentHostGrantStore）；这里不持有副本。
import AppKit
import AsterCore
import Foundation

/// 「Agent 访问」子页的协作者，由 `SettingsHostsBridge` 委托。
@MainActor
final class SettingsAgentAccessBridge {
  /// 本协作者处理的动作。
  static let actions: Set<String> = [
    "hosts.setAgentAccessEnabled", "hosts.revokeAgentGrant", "hosts.revokeAllAgentGrants",
    "hosts.agentAuditPage", "hosts.installAgentMCP",
  ]

  private weak var owner: SettingsHostsBridge?
  /// 运行时；测试注入。
  var runtime: () -> AgentHostRuntime? = { AgentHostRuntime.shared }
  /// MCP 安装；测试注入。
  var installMCP: (AgentHostMCPInstallService.Client) async -> AgentHostMCPInstallService.Outcome = { client in
    let locator = AgentExecutableLocator(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ProcessInfo.processInfo.environment, fileManager: .default)
    return await AgentHostMCPInstallService.install(client, locator: locator)
  }

  init(owner: SettingsHostsBridge) {
    self.owner = owner
  }

  /// 运行时状态变化时请求设置页刷新。
  func start() {
    runtime()?.onChange = { [weak self] in self?.owner?.scheduleRefresh() }
  }

  // MARK: - 快照

  /// 网页快照的 `hosts.agentAccess` 字段。
  func snapshot() -> [String: Any] {
    guard let runtime = runtime() else { return ["available": false, "enabled": false, "grants": [], "terminals": []] }
    let service = runtime.service
    let names = Dictionary(
      SSHHostDirectory.shared.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let order: [AgentHostGrantScope: Int] = [.always: 0, .session: 1, .once: 2]
    let grants = service.grants.grants.sorted {
      (order[$0.scope] ?? 3, $0.grantedAt) < (order[$1.scope] ?? 3, $1.grantedAt)
    }
    let cli = AgentHostMCPInstallService.stableCommandPath()
    var object: [String: Any] = [
      "available": true,
      "enabled": runtime.isEnabled,
      "grants": grants.map { grant -> [String: Any] in
        var row: [String: Any] = [
          "grantID": grant.grantID.uuidString,
          "hostID": grant.hostID.uuidString,
          "hostName": names[grant.hostID] ?? L("（主机已删除）"),
          "scope": grant.scope.rawValue,
          "grantedAt": AgentHostAuditRecord.timestamp(grant.grantedAt),
          "grantedBy": grant.grantedBy,
        ]
        row["session"] = grant.sessionKey
        return row
      },
      "terminals": service.registry.terminals.map { terminal -> [String: Any] in
        var row: [String: Any] = [
          "terminalID": terminal.terminalID,
          "hostName": terminal.hostName,
          "target": terminal.target,
          "agent": terminal.caller.displayName,
          "session": terminal.sessionKey,
          "state": terminal.state.rawValue,
          "paused": terminal.isPaused,
        ]
        row["runningCommandID"] = terminal.runningCommandID
        return row
      },
      "auditDirectory": (runtime.audit.directory.path as NSString).abbreviatingWithTildeInPath,
    ]
    object["cliPath"] = cli
    return object
  }

  // MARK: - 动作

  /// 分发动作；每个动作都以 `complete(succeeded)` 结束。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    guard let runtime = runtime() else {
      owner?.toast(L("agent 主机访问尚未启动"), true)
      complete(false)
      return
    }
    switch action {
    case "hosts.setAgentAccessEnabled":
      guard let enabled = payload["enabled"] as? Bool else { return fail(complete) }
      runtime.setEnabled(enabled)
      owner?.pushSnapshot()
      complete(true)
    case "hosts.revokeAgentGrant":
      guard let text = payload["grantID"] as? String, let id = UUID(uuidString: text) else { return fail(complete) }
      let revoked = runtime.service.grants.revoke(grantID: id, by: .current)
      owner?.pushSnapshot()
      if !revoked { owner?.toast(L("这条授权已不存在"), true) }
      complete(revoked)
    case "hosts.revokeAllAgentGrants":
      let count = runtime.service.grants.revokeAll(by: .current)
      owner?.pushSnapshot()
      owner?.toast(L("已撤销 \(count) 条授权"), false)
      complete(true)
    case "hosts.agentAuditPage":
      loadAuditPage(payload, runtime: runtime, complete: complete)
    case "hosts.installAgentMCP":
      guard let raw = payload["client"] as? String, let client = AgentHostMCPInstallService.Client(rawValue: raw) else {
        return fail(complete)
      }
      install(client, complete: complete)
    default:
      fail(complete)
    }
  }

  private func fail(_ complete: (Bool) -> Void) {
    owner?.toast(L("参数无效"), true)
    complete(false)
  }

  /// 读一页审计，经消息 `agentAccessAuditPage` 送给网页（读文件在后台）。
  private func loadAuditPage(_ payload: [String: Any], runtime: AgentHostRuntime, complete: @escaping (Bool) -> Void) {
    let before = payload["before"] as? String
    let limit = (payload["limit"] as? Int) ?? 20
    Task { @MainActor [weak self] in
      let page = await runtime.audit.page(before: before, limit: limit)
      let encoder = JSONEncoder()
      let records: [Any] = page.records.compactMap { record in
        guard let data = try? encoder.encode(record) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
      }
      var message: [String: Any] = ["type": "agentAccessAuditPage", "records": records]
      message["before"] = before
      message["nextBefore"] = page.nextBefore
      self?.owner?.postMessage(message)
      complete(true)
    }
  }

  /// 安装 MCP：成功 toast；失败把手动片段放进剪贴板并说明。
  private func install(_ client: AgentHostMCPInstallService.Client, complete: @escaping (Bool) -> Void) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let outcome = await self.installMCP(client)
      if let snippet = outcome.snippet {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
      }
      self.owner?.toast(outcome.message, !outcome.succeeded)
      complete(outcome.succeeded)
    }
  }
}
