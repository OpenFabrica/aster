// agent 主机终端的注册表：按（有效会话键，主机）复用终端，执行数量上限，
// 空闲 30 分钟自动关闭，随 App 退出，主机被删除时清理。终端不进任何工作区标签
// （停靠在 Pane 底部也只是借位显示，不是 Pane 的一部分）。
import AppKit
import AsterCore

/// 新建终端需要的信息。
struct AgentHostTerminalSpec: Sendable {
  var terminalID: String
  var hostID: UUID
  var hostName: String
  var target: String
  var caller: AgentHostResolvedCaller
}

/// 注册表。
@MainActor
final class AgentHostTerminalRegistry {
  /// 新建终端与面板；测试注入替身。
  typealias Factory = @MainActor (AgentHostTerminalSpec, AgentHostTerminalRegistry)
    -> (AgentHostTerminal, any AgentHostTerminalPresenting)

  static let maximumTerminals = 8
  static let maximumTerminalsPerSession = 4
  static let idleLimit: TimeInterval = 30 * 60

  private struct Entry {
    var terminal: AgentHostTerminal
    var presenter: any AgentHostTerminalPresenting
  }

  private var entries: [String: Entry] = [:]
  /// 创建顺序，菜单与列表按它排列。
  private var order: [String] = []
  private let factory: Factory
  private let now: () -> Date
  private var idleTimer: Timer?

  /// 命令结束（写审计）；由服务注入。
  var onCommandFinished: ((AgentHostTerminal, AgentHostCommandTracker.Finished) -> Void)?
  /// 命令等输入（发通知）；由服务注入。
  var onNeedsInput: ((AgentHostTerminal, String) -> Void)?
  /// 终端集合或状态变化（设置页、菜单刷新）。
  var onChange: (() -> Void)?

  init(factory: @escaping Factory, now: @escaping () -> Date = Date.init) {
    self.factory = factory
    self.now = now
  }

  var terminals: [AgentHostTerminal] { order.compactMap { entries[$0]?.terminal } }

  /// 本会话在该主机上仍活着的终端。
  func terminal(sessionKey: String, hostID: UUID) -> AgentHostTerminal? {
    terminals.first { $0.sessionKey == sessionKey && $0.hostID == hostID && $0.state != .ended }
  }

  func terminal(id: String) -> AgentHostTerminal? { entries[id]?.terminal }

  /// 运行中或最近完成过该命令的终端。
  func terminal(commandID: String) -> AgentHostTerminal? {
    terminals.first { $0.runningCommandID == commandID || $0.tracker.finishedCommand(commandID) != nil }
  }

  /// 取已有终端，没有就新建（检查数量上限）并显示面板。
  func obtain(_ spec: AgentHostTerminalSpec) throws -> AgentHostTerminal {
    if let existing = terminal(sessionKey: spec.caller.key, hostID: spec.hostID) {
      entries[existing.terminalID]?.presenter.show(attention: false)
      return existing
    }
    let live = terminals.filter { $0.state != .ended }
    guard live.count < Self.maximumTerminals else {
      throw AsterControlError(code: .limitExceeded, message: "agent 终端最多同时 \(Self.maximumTerminals) 个")
    }
    guard live.filter({ $0.sessionKey == spec.caller.key }).count < Self.maximumTerminalsPerSession else {
      throw AsterControlError(
        code: .limitExceeded, message: "同一 agent 会话最多 \(Self.maximumTerminalsPerSession) 个终端")
    }
    let (terminal, presenter) = factory(spec, self)
    entries[terminal.terminalID] = Entry(terminal: terminal, presenter: presenter)
    order.append(terminal.terminalID)
    wire(terminal, presenter: presenter)
    presenter.show(attention: false)
    terminal.start()
    startIdleTimer()
    onChange?()
    return terminal
  }

  /// 把终端回调接到面板刷新、提醒与注册表清理上。
  private func wire(_ terminal: AgentHostTerminal, presenter: any AgentHostTerminalPresenting) {
    let id = terminal.terminalID
    terminal.onChange = { [weak self] in
      self?.entries[id]?.presenter.refresh()
      self?.onChange?()
    }
    terminal.onNeedsInput = { [weak self] prompt in
      guard let self, let entry = self.entries[id] else { return }
      entry.presenter.show(attention: true)
      self.onNeedsInput?(entry.terminal, prompt)
    }
    terminal.onCommandFinished = { [weak self] result in
      guard let self, let terminal = self.entries[id]?.terminal else { return }
      self.onCommandFinished?(terminal, result)
    }
    terminal.onEnded = { [weak self] in
      self?.entries[id]?.presenter.refresh()
      self?.onChange?()
    }
  }

  /// 关闭一个终端并移除面板。
  func close(_ terminal: AgentHostTerminal) {
    remove(terminal.terminalID)
  }

  /// 从注册表移除。终端还没结束时先关掉它：必须在移除条目之前，命令收尾的审计回调要靠条目找到终端。
  func remove(_ terminalID: String) {
    entries[terminalID]?.terminal.close()
    guard let entry = entries.removeValue(forKey: terminalID) else { return }
    order.removeAll { $0 == terminalID }
    entry.presenter.close()
    if entries.isEmpty {
      idleTimer?.invalidate()
      idleTimer = nil
    }
    onChange?()
  }

  /// 主机已不存在（被删除）的终端全部关闭。
  func closeTerminals(notIn hostIDs: Set<UUID>) {
    for terminal in terminals where !hostIDs.contains(terminal.hostID) { close(terminal) }
  }

  /// 同步主机改名。
  func updateHostNames(_ names: [UUID: String]) {
    for terminal in terminals { if let name = names[terminal.hostID] { terminal.updateHostName(name) } }
  }

  /// 关闭全部（App 退出）。
  func closeAll() {
    for terminal in terminals { close(terminal) }
  }

  /// 把终端找回来（窗口菜单）：浮窗置前；停靠时展开停靠区并切到那个 Pane。
  func reveal(_ terminalID: String) {
    entries[terminalID]?.presenter.reveal()
  }

  /// 停在已关闭 Pane 里的终端转成浮窗（`isClosed` 判定 Pane 是否已关）。
  func handlePanesClosed(where isClosed: (UUID) -> Bool) {
    for id in order { entries[id]?.presenter.handlePanesClosed(where: isClosed) }
  }

  // MARK: - 键盘归属

  /// 浮窗就是 `keyWindow` 的那个终端的呈现器。
  private func presenter(owningKeyWindow keyWindow: NSWindow) -> (any AgentHostTerminalPresenting)? {
    order.lazy.compactMap { self.entries[$0]?.presenter }.first { $0.ownsKeyWindow(keyWindow) }
  }

  /// 某个 agent 终端的浮窗是不是 key 窗口；菜单据此禁用只作用于背后工作区的命令。
  func ownsKeyWindow(_ keyWindow: NSWindow) -> Bool {
    presenter(owningKeyWindow: keyWindow) != nil
  }

  /// 关闭快捷键落在 agent 浮窗上：收起它并返回 true；否则返回 false，由工作区照常处理。
  func handleCloseShortcut(in keyWindow: NSWindow) -> Bool {
    guard let presenter = presenter(owningKeyWindow: keyWindow) else { return false }
    presenter.hideForCloseShortcut()
    return true
  }

  // MARK: - 空闲关闭

  private func startIdleTimer() {
    guard idleTimer == nil else { return }
    let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.closeIdleTerminals() }
    }
    RunLoop.main.add(timer, forMode: .common)
    idleTimer = timer
  }

  /// 空闲超过 30 分钟（且没有命令在跑）的终端自动关闭；已结束的直接移除。
  func closeIdleTerminals() {
    let current = now()
    for terminal in terminals {
      if terminal.state == .ended {
        remove(terminal.terminalID)
      } else if terminal.runningCommandID == nil,
        current.timeIntervalSince(terminal.lastActivity) >= Self.idleLimit
      {
        close(terminal)
      }
    }
  }

  // MARK: - 菜单

  /// 「窗口 → Agent 终端」子菜单的条目。
  func menuItems(target: AnyObject, action: Selector) -> [NSMenuItem] {
    terminals.map { terminal in
      let item = NSMenuItem(
        title: "\(terminal.caller.displayName) → \(terminal.hostName)", action: action, keyEquivalent: "")
      item.target = target
      item.representedObject = terminal.terminalID
      return item
    }
  }
}
