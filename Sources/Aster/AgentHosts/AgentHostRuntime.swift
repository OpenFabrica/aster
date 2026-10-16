// agent 远程执行的生产装配：审计日志、授权存储（钥匙串）、批准协调、终端注册表与服务。
// 还负责 App 级生命周期：主机删除 / 改名同步、退出确认、「窗口 → Agent 终端」菜单与设置开关。
import AppKit
import AsterCore
import Combine

/// 生产运行时。只在 App 启动时创建一次。
@MainActor
final class AgentHostRuntime: NSObject, WorkspaceTerminationParticipant, NSMenuDelegate {
  static private(set) var shared: AgentHostRuntime?

  let preferences: AppPreferences
  let service: AgentHostService
  let audit: AgentHostAuditLog
  private var cancellables: Set<AnyCancellable> = []
  /// 设置页刷新（授权、终端、开关变化）。
  var onChange: (() -> Void)?

  /// 装配并登记为共享实例；`resolvePane` 把 `$ASTER_PANE_ID` 解析成 Pane 与其中的 agent。
  @discardableResult
  static func install(
    preferences: AppPreferences,
    resolvePane: @escaping @MainActor (String) -> (pane: String, provider: AgentProvider?, agentSessionID: String?)?
  ) -> AgentHostRuntime {
    if let shared { return shared }
    let runtime = AgentHostRuntime(preferences: preferences, resolvePane: resolvePane)
    shared = runtime
    AgentHostService.shared = runtime.service
    return runtime
  }

  private init(
    preferences: AppPreferences,
    resolvePane: @escaping @MainActor (String) -> (pane: String, provider: AgentProvider?, agentSessionID: String?)?
  ) {
    self.preferences = preferences
    let audit = AgentHostAuditLog.shared
    self.audit = audit
    let directory = SSHHostDirectory.shared
    let grants = AgentHostGrantStore(
      persistence: AgentHostGrantKeychain(), audit: audit,
      hostLookup: { id in
        guard let profile = directory.host(id) else { return nil }
        let target = (try? SSHHostResolver.resolve(id, in: directory.hosts).credentialEndpoint) ?? profile.host
        return .init(id: id.uuidString, name: profile.name, target: target)
      })
    let registry = AgentHostTerminalRegistry { spec, registry in
      Self.makeTerminal(spec, registry: registry, preferences: preferences)
    }
    service = AgentHostService(
      dependencies: .init(
        hosts: { directory.hosts },
        isEnabled: { [weak preferences] in preferences?.agentHostAccessEnabled ?? false },
        grants: grants, approvals: AgentHostApprovalCoordinator(), registry: registry, audit: audit,
        user: .current, resolvePane: resolvePane))
    super.init()
    registry.onNeedsInput = { [weak self] terminal, prompt in self?.notifyNeedsInput(terminal, prompt: prompt) }
    registry.onChange = { [weak self] in self?.onChange?() }
    grants.onChange = { [weak self] in self?.onChange?() }
    audit.pruneExpired()
    Task { await grants.loadIfNeeded() }
    // @Published 在 willSet 发出，切到下一轮主队列再读新值。
    directory.$hosts.receive(on: DispatchQueue.main).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.synchronizeHosts() }
    }.store(in: &cancellables)
  }

  /// 生产终端：原生 SSH 会话 + 浮动面板；面板按钮接到终端与注册表。
  private static func makeTerminal(
    _ spec: AgentHostTerminalSpec, registry: AgentHostTerminalRegistry, preferences: AppPreferences
  ) -> (AgentHostTerminal, any AgentHostTerminalPresenting) {
    let surface = LiveAgentHostTerminalSurface(hostID: spec.hostID, preferences: preferences)
    let terminal = AgentHostTerminal(
      terminalID: spec.terminalID, hostID: spec.hostID, hostName: spec.hostName, target: spec.target,
      sessionKey: spec.caller.key, caller: spec.caller, surface: surface)
    let panel = AgentHostTerminalPanelController(
      terminal: terminal, hostView: surface.hostView, preferences: preferences,
      actions: .init(
        interrupt: { [weak terminal] in terminal?.userInterrupt() },
        togglePause: { [weak terminal] in terminal?.isPaused.toggle() },
        closeTerminal: { [weak registry, weak terminal] in
          guard let registry, let terminal else { return }
          registry.close(terminal)
        }))
    // 用户在终端里 `exit`：收尾运行中的命令（写审计）并关掉面板。回调发自会话自己的退出处理，
    // 延后一轮再拆 surface，与 Quick Terminal 相同。
    surface.session.onRequestCloseAfterExit = { [weak registry, weak terminal] in
      DispatchQueue.main.async {
        guard let registry, let terminal else { return }
        registry.close(terminal)
      }
    }
    return (terminal, panel)
  }

  // MARK: - 主机同步

  /// 主机删除：关终端、作废授权、撤掉挂起的批准面板；主机改名：同步终端标题。
  private func synchronizeHosts() {
    let hosts = SSHHostDirectory.shared.savedHosts
    let ids = Set(hosts.map(\.id))
    service.registry.closeTerminals(notIn: ids)
    service.registry.updateHostNames(Dictionary(hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    let staleHostIDs = Set(service.grants.grants.map(\.hostID)).subtracting(ids)
    for hostID in staleHostIDs {
      service.grants.removeGrants(forHost: hostID, hostName: "（主机已删除）")
      service.dependencies.approvals.dismissAll(hostID: hostID)
    }
  }

  // MARK: - 设置

  var isEnabled: Bool { preferences.agentHostAccessEnabled }

  /// 设置页开关：写偏好并记一条 `setting.changed` 审计（前后值）。
  func setEnabled(_ enabled: Bool) {
    let previous = preferences.agentHostAccessEnabled
    guard previous != enabled else { return }
    preferences.agentHostAccessEnabled = enabled
    let user = AgentHostLocalUser.current
    audit.append(
      AgentHostAuditRecord(
        time: Date(), action: .settingChanged, actor: .user(account: user.account, name: user.name),
        changes: [.init(field: "agentHostAccessEnabled", before: Self.onOff(previous), after: Self.onOff(enabled))]))
    if !enabled { service.dependencies.approvals.dismissAll(hostID: nil) }
    onChange?()
  }

  private static func onOff(_ value: Bool) -> String { value ? "开启" : "关闭" }

  // MARK: - 提醒

  /// 命令等输入：系统通知（面板已由注册表置前并请求注意）。
  private func notifyNeedsInput(_ terminal: AgentHostTerminal, prompt: String) {
    TerminalNotificationService.shared.post(
      TerminalNotification(
        title: L("\(terminal.hostName) 上的命令在等你输入"), body: prompt, urgency: .critical),
      category: .application, configuration: preferences.configuration.shell, sourceTabIsFocused: false)
  }

  // MARK: - 退出

  /// 有 agent 命令在跑时确认退出。
  func confirmTermination() -> Bool {
    let busy = service.registry.terminals.filter { $0.runningCommandID != nil }
    guard !busy.isEmpty else { return true }
    let alert = NSAlert()
    alert.messageText = L("退出 Aster？")
    alert.informativeText = L("有 \(busy.count) 个 agent 终端正在远程主机上运行命令，退出会断开这些 SSH 连接。")
    alert.addButton(withTitle: L("退出"))
    alert.addButton(withTitle: L("取消"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  func commitTermination() { shutdown() }

  /// 关闭全部终端与批准面板。
  func shutdown() {
    service.dependencies.approvals.dismissAll(hostID: nil)
    service.registry.closeAll()
  }

  // MARK: - 窗口菜单

  /// 「窗口 → Agent 终端」子菜单项；内容在打开时按当前终端生成。
  func makeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: L("Agent 终端"), action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: L("Agent 终端"))
    submenu.delegate = self
    item.submenu = submenu
    return item
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let items = service.registry.menuItems(target: self, action: #selector(revealTerminal(_:)))
    if items.isEmpty {
      let empty = NSMenuItem(title: L("没有 agent 终端"), action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    } else {
      items.forEach(menu.addItem)
    }
  }

  @objc private func revealTerminal(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    service.registry.reveal(id)
  }
}
