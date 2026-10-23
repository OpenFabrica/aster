// agent 主机终端的呈现：同一份内容（终端 + 遮罩 + 控制胶囊）停靠在调用方 Pane 底部，或放进独立浮窗。
// 浮窗一开始就建好并装上内容（停车位），让 Ghostty surface 立刻创建、SSH 立刻连上；停靠时浮窗不显示。
// 两处之间搬动不重建终端、不中断远端命令；用户主动「弹出 / 停靠」时记住选择，之后的新终端照此办理。
import AppKit
import AsterCore

/// 终端呈现的最小接口；测试用替身，不建窗口。
@MainActor
protocol AgentHostTerminalPresenting: AnyObject {
  /// 显示（不抢焦点）：浮窗置前；停靠时展开停靠区并选中这个终端，不动任何窗口。
  /// `attention` 为 true 时还请求注意（等输入）。
  func show(attention: Bool)
  /// 「窗口 ▸ Agent 终端」找回：浮窗置前；停靠时展开停靠区，并切到那个 Pane、前置它的窗口。
  func reveal()
  /// 状态变化后刷新标题与头部。
  func refresh()
  /// 关闭（终端已结束或被关闭）：撤出停靠区，关掉浮窗。
  func close()
  /// `keyWindow` 是否就是这个终端的浮窗。是的话 ⌘W 等工作区命令不能落到背后的工作区。
  func ownsKeyWindow(_ keyWindow: NSWindow) -> Bool
  /// 关闭快捷键（⌘W / ⌥⌘W）：收起浮窗，同标题栏关闭按钮；终端照常运行。
  func hideForCloseShortcut()
  /// 停靠的 Pane 已关闭（`isClosed` 判定为真）：转成浮窗显示，不关终端。
  func handlePanesClosed(where isClosed: (UUID) -> Bool)
}

/// agent 主机终端默认放在哪；用户点「弹出 / 停靠」时写进偏好。
enum AgentHostTerminalPresentation: String {
  /// 停靠在调用 agent 的 Pane 底部（默认）。
  case docked
  /// 独立浮窗。
  case window
}

/// 生产实现：每个终端一个。
@MainActor
final class AgentHostTerminalPresenter: NSObject, AgentHostTerminalPresenting {
  /// 用户在控制胶囊上的动作。
  struct Actions {
    var interrupt: @MainActor () -> Void
    /// 切换暂停：暂停即用户接管，agent 的新命令一律被拒。
    var togglePause: @MainActor () -> Void
    /// 把键盘焦点交给终端视图（接管后、遮罩撤掉后）。
    var focusTerminal: @MainActor () -> Void
    var closeTerminal: @MainActor () -> Void
  }

  /// 终端此刻的去处。
  enum Placement: Equatable {
    case window
    /// 停靠在这个 Pane（UUID）底部。
    case docked(UUID)
  }

  private weak var terminal: AgentHostTerminal?
  private let terminalID: String
  private let preferences: AppPreferences
  private let docks: AgentHostPaneDocks
  private let locator: (any AgentHostPaneLocator)?
  private let actions: Actions
  private let controlBar = AgentHostTerminalControlBar()
  /// 终端 + 遮罩 + 控制胶囊，整体在浮窗与停靠区之间搬。
  private let content: AgentHostTerminalContentView
  /// 浮窗；停靠时也一直留着当停车位。
  let panel: AgentHostTerminalPanelController
  private(set) var placement: Placement = .window

  /// 建好内容并先装进浮窗（停车位）；偏好是停靠且调用方 Pane 还在时立刻搬进 Pane，否则用浮窗。
  init(
    terminal: AgentHostTerminal, hostView: NSView, preferences: AppPreferences, docks: AgentHostPaneDocks,
    locator: (any AgentHostPaneLocator)?, actions: Actions
  ) {
    self.terminal = terminal
    terminalID = terminal.terminalID
    self.preferences = preferences
    self.docks = docks
    self.locator = locator
    self.actions = actions
    content = AgentHostTerminalContentView(
      controlBar: controlBar, hostView: hostView, focusTerminal: actions.focusTerminal)
    panel = AgentHostTerminalPanelController(preferences: preferences)
    super.init()
    configure(controlBar.interruptButton, title: L("中断"), action: #selector(interruptClicked))
    configure(controlBar.pauseButton, title: L("接管"), action: #selector(pauseClicked))
    configure(controlBar.closeButton, title: L("关闭终端"), action: #selector(closeClicked))
    panel.allowsClose = { [weak terminal] in terminal?.state == .ended }
    panel.onDock = { [weak self] in self?.dockToPane() }
    panel.install(content)
    if preferences.agentHostTerminalPresentation == .docked, let paneID = livePaneID {
      dock(in: paneID)
    }
    refresh()
  }

  /// 浮窗标题，例如「Claude Code → prod-db (deploy@10.0.0.5:22)」。
  var title: String { panel.title }

  /// 调用方 Pane 还在时的 UUID；没有定位器、agent 不在 Aster 里跑或 Pane 已关时为 nil。
  private var livePaneID: UUID? {
    guard let paneID = terminal?.caller.paneUUID, locator?.isPaneAlive(paneID) == true else { return nil }
    return paneID
  }

  // MARK: - AgentHostTerminalPresenting

  func show(attention: Bool) {
    undockIfPaneClosed()
    switch placement {
    case .window: panel.show()
    case .docked: docks.reveal(terminalID)
    }
    if attention { NSApp.requestUserAttention(.informationalRequest) }
  }

  func reveal() {
    undockIfPaneClosed()
    switch placement {
    case .window: panel.show()
    case .docked(let paneID):
      docks.reveal(terminalID)
      locator?.revealPane(paneID)
    }
  }

  /// 刷新标题、控制胶囊与遮罩；停靠时同步停靠区的标签，浮窗时同步「停靠到 Pane」按钮。
  func refresh() {
    guard let terminal else { return }
    let (status, tone) = Self.status(of: terminal)
    panel.title = "\(terminal.caller.displayName) → \(terminal.hostName) (\(terminal.target))"
    controlBar.update(title: "\(terminal.caller.displayName) → \(terminal.hostName)", status: status, tone: tone)
    controlBar.interruptButton.isEnabled = terminal.state == .busy || terminal.state == .needsInput
    controlBar.pauseButton.isEnabled = terminal.state != .ended
    controlBar.pauseButton.title = terminal.isPaused ? L("交还 agent") : L("接管")
    // 遮罩只在用户接管后撤掉：空闲、等输入时也挡住输入，防止按键和 agent 的命令交错。
    content.setAgentControlling(terminal.blocksUserInput)
    content.setAgentWorking(terminal.state == .connecting || terminal.state == .busy)
    // 更新控件布局；胶囊尺寸只跟随可用宽度，不随状态文案伸缩。
    content.needsLayout = true
    switch placement {
    case .docked: docks.update(terminalID, tab: dockTab(for: terminal, tone: tone))
    case .window: panel.setDockAvailable(livePaneID != nil)
    }
  }

  func close() {
    docks.detach(terminalID)
    panel.close()
  }

  func ownsKeyWindow(_ keyWindow: NSWindow) -> Bool { keyWindow === panel.window }

  /// 走标题栏关闭按钮的同一条路径：终端没结束时只隐藏。
  func hideForCloseShortcut() { panel.performClose() }

  /// Pane 关了不写偏好、不关终端（免得误杀远端命令），只是换到浮窗。
  func handlePanesClosed(where isClosed: (UUID) -> Bool) {
    guard case .docked(let paneID) = placement, isClosed(paneID) else { return }
    moveToWindow()
  }

  // MARK: - 切换去处

  /// 用户点「弹出为独立窗口」：搬进浮窗并记住选择。接管中把焦点交给终端，否则不抢焦点。
  func popOut() {
    guard case .docked = placement else { return }
    preferences.agentHostTerminalPresentation = .window
    moveToWindow()
    guard terminal?.isPaused == true else { return }
    panel.makeKey()
    actions.focusTerminal()
  }

  /// 用户点浮窗标题栏的「停靠到 Pane」：搬回调用方 Pane 底部、记住选择，并切到那个 Pane——
  /// 它可能在后台标签里，不切过去终端就像凭空消失了。焦点交给工作区按活动 Pane 落，不抢。
  func dockToPane() {
    guard placement == .window, let paneID = livePaneID else {
      panel.setDockAvailable(false)
      return
    }
    preferences.agentHostTerminalPresentation = .docked
    panel.hide()
    dock(in: paneID)
    locator?.revealPane(paneID)
  }

  /// 搬进 Pane 停靠区（同一轮主循环里先从浮窗摘下再装上，surface 不断）。
  private func dock(in paneID: UUID) {
    guard let terminal else { return }
    placement = .docked(paneID)
    docks.attach(
      .init(
        terminalID: terminalID, content: content, tab: dockTab(for: terminal, tone: Self.status(of: terminal).1),
        popOut: { [weak self] in self?.popOut() }),
      to: paneID)
  }

  /// 搬进浮窗并显示。
  private func moveToWindow() {
    docks.detach(terminalID)
    panel.install(content)
    placement = .window
    refresh()
    panel.show()
  }

  /// 停靠的 Pane 没收到关闭通知就不在了（兜底）：转成浮窗。
  private func undockIfPaneClosed() {
    guard let locator else { return }
    handlePanesClosed { !locator.isPaneAlive($0) }
  }

  // MARK: - 头部

  /// 头部状态文案与语气。
  private static func status(of terminal: AgentHostTerminal) -> (String, AgentHostTerminalControlBar.Tone) {
    let command = terminal.tracker.running?.command.split(separator: "\n").first.map(String.init) ?? ""
    switch terminal.state {
    case .connecting: return (L("正在连接…"), .active)
    case .ready: return terminal.isPaused ? (L("空闲 · agent 已暂停"), .paused) : (L("空闲"), .idle)
    case .busy: return (L("正在运行：\(command)"), .active)
    case .needsInput: return (L("等待你的输入：点「接管」后在终端里回答"), .attention)
    case .ended: return (L("终端已结束"), .ended)
    }
  }

  /// 停靠区里的标签：主机名 + 状态色点，悬停显示调用方与目标。
  private func dockTab(for terminal: AgentHostTerminal, tone: AgentHostTerminalControlBar.Tone) -> AgentHostPaneDockView.Tab {
    .init(
      terminalID: terminalID, title: terminal.hostName,
      toolTip: "\(terminal.caller.displayName) → \(terminal.hostName) (\(terminal.target))", tone: tone)
  }

  private func configure(_ button: NSButton, title: String, action: Selector) {
    button.title = title
    button.target = self
    button.action = action
  }

  @objc private func interruptClicked() { actions.interrupt() }

  /// 「接管」暂停 agent，让终端所在的窗口成为 key 并把焦点交给终端，用户马上就能打字；
  /// 停靠时是工作区窗口，浮窗时是浮窗。「交还 agent」只恢复。
  @objc private func pauseClicked() {
    actions.togglePause()
    guard terminal?.isPaused == true else { return }
    switch placement {
    case .window: panel.makeKey()
    case .docked: content.window?.makeKey()
    }
    actions.focusTerminal()
  }

  @objc private func closeClicked() { actions.closeTerminal() }
}
