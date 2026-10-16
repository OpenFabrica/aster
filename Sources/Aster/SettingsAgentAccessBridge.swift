// 设置页「主机」分类的桥接：该分类只剩「Agent 访问」（开关、授权、agent 终端、MCP 安装、审计）
// 与一个打开侧栏主机页的入口。主机、密钥与已知主机的管理都在侧栏「主机」页，这里不再提供。
// 真值在 AgentHostRuntime（开关在 AppPreferences，授权在 AgentHostGrantStore）；这里不持有副本。
//
// `SettingsViewController` 只负责把消息转进来、把快照与回执送出去；它的 private 成员
// 不对这里开放，需要的能力（推送快照、toast、向网页发消息）都以闭包注入。
import AppKit
import AsterCore
import Combine
import Foundation

/// 设置页「主机」分类（Agent 访问）的快照与动作处理。
@MainActor
final class SettingsAgentAccessBridge {
  /// 本协作者处理的动作；均以 `hosts.` 为前缀，沿用网页既有的分类前缀。
  static let actions: Set<String> = [
    "hosts.setAgentAccessEnabled", "hosts.revokeAgentGrant", "hosts.revokeAllAgentGrants",
    "hosts.agentAuditPage", "hosts.installAgentMCP", "hosts.openHostsPage",
  ]

  /// 立即推送一份新快照。动作成功后先推快照再发回执，网页拿到回执时页面已是新值。
  var pushSnapshot: () -> Void = {}
  /// 运行时或主机名变化时请求刷新；可以是异步合并的刷新。
  var scheduleRefresh: () -> Void = {}
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }
  /// 向网页发送一条结构化消息（审计分页）。
  var postMessage: ([String: Any]) -> Void = { _ in }
  /// 「打开主机页」：在最前面的工作区窗口里显示侧栏主机页；测试注入。
  var openHostsPage: @MainActor () -> Void = {
    (NSApp.delegate as? AsterAppDelegate)?.showHostsPage()
  }
  /// 授权行显示主机名用的目录；测试注入临时目录。
  let hosts: SSHHostDirectory
  private var cancellables: Set<AnyCancellable> = []

  /// 运行时；测试注入。
  var runtime: () -> AgentHostRuntime? = { AgentHostRuntime.shared }
  /// MCP 安装；测试注入。
  var installMCP: (AgentHostMCPInstallService.Client) async -> AgentHostMCPInstallService.Outcome = { client in
    let locator = AgentExecutableLocator(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      environment: ProcessInfo.processInfo.environment, fileManager: .default)
    return await AgentHostMCPInstallService.install(client, locator: locator)
  }

  /// 读取客户端登记状态；测试注入。真实实现读 `~/.claude.json` 与 `~/.codex/config.toml`。
  var readRegistrations: @Sendable () -> [AgentHostMCPInstallService.Client: (command: String?, status: AgentHostMCPRegistration.Status)] = {
    AgentHostMCPInstallService.registrations()
  }
  /// 最近一次读取的登记状态（快照只读这份缓存，读文件在后台）。
  private(set) var registrations: [AgentHostMCPInstallService.Client: (command: String?, status: AgentHostMCPRegistration.Status)] = [:]

  init(hosts: SSHHostDirectory = .shared) {
    self.hosts = hosts
  }

  /// 运行时状态或主机名变化时请求设置页刷新；同时在后台检查已登记的 MCP 命令是否会失效。
  /// 重复调用无副作用。
  func start() {
    guard cancellables.isEmpty else { return }
    runtime()?.onChange = { [weak self] in self?.scheduleRefresh() }
    // 授权行按主机 ID 显示名称；主机在侧栏主机页改名或删除时，设置页跟着重绘。
    hosts.$hosts
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    refreshRegistrations()
  }

  /// 后台重读客户端配置里的 aster 登记，回到主线程后刷新快照。
  func refreshRegistrations() {
    let read = readRegistrations
    Task { @MainActor [weak self] in
      let result = await Task.detached(priority: .utility) { read() }.value
      guard let self else { return }
      self.registrations = result
      self.scheduleRefresh()
    }
  }

  // MARK: - 快照

  /// 网页快照的 `hosts` 字段：只有 `agentAccess`（见 `agentAccessSnapshot`）。
  func snapshot() -> [String: Any] {
    ["agentAccess": agentAccessSnapshot()]
  }

  /// 网页快照的 `hosts.agentAccess` 字段。
  func agentAccessSnapshot() -> [String: Any] {
    guard let runtime = runtime() else { return ["available": false, "enabled": false, "grants": [], "terminals": []] }
    let service = runtime.service
    let names = Dictionary(
      hosts.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
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
    object["registrations"] = Dictionary(uniqueKeysWithValues: registrations.map { client, entry -> (String, Any) in
      var row: [String: Any] = ["status": entry.status.rawValue]
      row["command"] = entry.command
      return (client.rawValue, row)
    })
    return object
  }

  // MARK: - 动作

  /// 分发动作；每个动作都以 `complete(succeeded)` 结束。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    guard Self.actions.contains(action) else {
      toast(L("“\(action)”尚无可用的 macOS 操作"), true)
      complete(false)
      return
    }
    // 打开主机页不依赖 agent 运行时，先于运行时检查处理。
    if action == "hosts.openHostsPage" {
      openHostsPage()
      complete(true)
      return
    }
    guard let runtime = runtime() else {
      toast(L("agent 主机访问尚未启动"), true)
      complete(false)
      return
    }
    switch action {
    case "hosts.setAgentAccessEnabled":
      guard let enabled = payload["enabled"] as? Bool else { return fail(complete) }
      runtime.setEnabled(enabled)
      pushSnapshot()
      complete(true)
    case "hosts.revokeAgentGrant":
      guard let text = payload["grantID"] as? String, let id = UUID(uuidString: text) else { return fail(complete) }
      let revoked = runtime.service.grants.revoke(grantID: id, by: .current)
      pushSnapshot()
      if !revoked { toast(L("这条授权已不存在"), true) }
      complete(revoked)
    case "hosts.revokeAllAgentGrants":
      let count = runtime.service.grants.revokeAll(by: .current)
      pushSnapshot()
      toast(L("已撤销 \(count) 条授权"), false)
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
    toast(L("参数无效"), true)
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
      self?.postMessage(message)
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
      self.toast(outcome.message, !outcome.succeeded)
      self.refreshRegistrations()
      complete(outcome.succeeded)
    }
  }
}
