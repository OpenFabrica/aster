// agent 主机终端的浮动窗口：用户看着 agent 在真实 SSH 终端里干活。agent 操作时终端盖着遮罩、
// 不接受输入；用户点「接管」暂停 agent 后才能打字，也可以中断命令或关闭终端。
// 面板不抢焦点（nonactivating），用户点进终端或点「接管」才成为 key。
import AppKit
import AsterCore

/// 终端面板的最小接口；测试用替身，不建窗口。
@MainActor
protocol AgentHostTerminalPresenting: AnyObject {
  /// 显示（不抢焦点）。`attention` 为 true 时置前并请求注意（等输入）。
  func show(attention: Bool)
  /// 状态变化后刷新标题与头部。
  func refresh()
  /// 关闭窗口（终端已结束或被关闭）。
  func close()
}

/// 生产实现：每个终端一个 NSPanel。
@MainActor
final class AgentHostTerminalPanelController: NSObject, AgentHostTerminalPresenting, NSWindowDelegate {
  /// 用户在面板里的动作。
  struct Actions {
    var interrupt: @MainActor () -> Void
    /// 切换暂停：暂停即用户接管，agent 的新命令一律被拒。
    var togglePause: @MainActor () -> Void
    /// 把键盘焦点交给终端视图（接管后、遮罩撤掉后）。
    var focusTerminal: @MainActor () -> Void
    var closeTerminal: @MainActor () -> Void
  }

  /// 新窗口相对上一个的错位，多个终端不完全重叠。
  private static var cascadePoint = NSPoint.zero

  private weak var terminal: AgentHostTerminal?
  private let panel: AgentHostTerminalPanel
  private let actions: Actions
  private let controlBar = AgentHostTerminalControlBar()
  private var content: AgentHostTerminalContentView?

  init(terminal: AgentHostTerminal, hostView: NSView, preferences: AppPreferences, actions: Actions) {
    self.terminal = terminal
    self.actions = actions
    panel = AgentHostTerminalPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 420, height: 220)
    panel.delegate = self
    panel.appearance = preferences.preferredAppearance
    panel.contentView = makeContent(hostView: hostView)
    panel.center()
    Self.cascadePoint = panel.cascadeTopLeft(from: Self.cascadePoint)
    refresh()
  }

  /// 窗口标题，例如「Claude Code → prod-db (deploy@10.0.0.5:22)」。
  var title: String { panel.title }

  func show(attention: Bool) {
    panel.orderFrontRegardless()
    if attention { NSApp.requestUserAttention(.informationalRequest) }
  }

  /// 刷新标题与头部状态。
  func refresh() {
    guard let terminal else { return }
    panel.title = "\(terminal.caller.displayName) → \(terminal.hostName) (\(terminal.target))"
    let command = terminal.tracker.running?.command.split(separator: "\n").first.map(String.init) ?? ""
    let status: String
    let tone: AgentHostTerminalControlBar.Tone
    switch terminal.state {
    case .connecting: (status, tone) = (L("正在连接…"), .active)
    case .ready:
      (status, tone) = terminal.isPaused ? (L("空闲 · agent 已暂停"), .paused) : (L("空闲"), .idle)
    case .busy: (status, tone) = (L("正在运行：\(command)"), .active)
    case .needsInput: (status, tone) = (L("等待你的输入：请直接在下面的终端里回答"), .attention)
    case .ended: (status, tone) = (L("终端已结束"), .ended)
    }
    controlBar.update(title: "\(terminal.caller.displayName) → \(terminal.hostName)", status: status, tone: tone)
    controlBar.interruptButton.isEnabled = terminal.state == .busy || terminal.state == .needsInput
    controlBar.pauseButton.isEnabled = terminal.state != .ended
    // 只有 agent 真正在操作终端（连接、跑命令）时盖遮罩；等输入、空闲、暂停时撤掉，不干扰用户。
    controlBar.pauseButton.title = terminal.isPaused ? L("交还 agent") : L("接管")
    // agent 真正在操作终端（连接、跑命令）且没被接管时盖遮罩、挡输入；等输入、空闲、接管后撤掉。
    let agentControlling = (terminal.state == .connecting || terminal.state == .busy) && !terminal.isPaused
    content?.setAgentControlling(agentControlling)
    // 更新控件布局；胶囊尺寸只跟随窗口可用宽度，不随状态文案伸缩。
    content?.needsLayout = true
  }

  func close() {
    panel.delegate = nil
    panel.orderOut(nil)
    panel.close()
  }

  /// 标题栏关闭只隐藏面板，终端照常运行；「窗口 → Agent 终端」可以找回。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if terminal?.state == .ended { return true }
    panel.orderOut(nil)
    return false
  }

  // MARK: - 布局

  private func makeContent(hostView: NSView) -> NSView {
    configure(controlBar.interruptButton, title: L("中断"), action: #selector(interruptClicked))
    configure(controlBar.pauseButton, title: L("接管"), action: #selector(pauseClicked))
    configure(controlBar.closeButton, title: L("关闭终端"), action: #selector(closeClicked))

    let container = AgentHostTerminalContentView(
      controlBar: controlBar, hostView: hostView, focusTerminal: actions.focusTerminal)
    content = container
    container.wantsLayer = true
    // 强调色边框：一眼认出这是 agent 在操作的终端，不是自己的工作区。
    container.layer?.borderColor = NSColor.controlAccentColor.cgColor
    container.layer?.borderWidth = 2
    return container
  }

  private func configure(_ button: NSButton, title: String, action: Selector) {
    button.title = title
    button.target = self
    button.action = action
  }

  @objc private func interruptClicked() { actions.interrupt() }
  /// 「接管」暂停 agent 并把焦点交给终端，用户马上就能打字；「交还 agent」只恢复。
  @objc private func pauseClicked() {
    actions.togglePause()
    guard terminal?.isPaused == true else { return }
    panel.makeKey()
    actions.focusTerminal()
  }
  @objc private func closeClicked() { actions.closeTerminal() }
}

/// 允许成为 key（用户要在里面打字），但不成为 main，不改变工作区窗口的主窗口身份。
@MainActor
private final class AgentHostTerminalPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// 终端 + 控制遮罩 + 浮动控制胶囊的容器。用 frame 布局而不是约束：终端宿主是 frame 挂载的长期复用视图，
/// 与 Quick Terminal 一样避免混用约束（见 QuickTerminalController.installTerminalHost）。
@MainActor
final class AgentHostTerminalContentView: NSView {
  /// 胶囊默认离终端底边的距离，以及拖动时离四边的最小距离。
  private static let barBottomMargin: CGFloat = 16
  private static let barEdgeMargin: CGFloat = 8
  private let controlBar: AgentHostTerminalControlBar
  private let hostView: NSView
  private let focusTerminal: @MainActor () -> Void
  /// 盖在终端上方的「agent 正在控制」遮罩。
  private let controlOverlay = AgentHostTerminalControlOverlay()
  /// 用户拖过胶囊后的位置；nil 时用默认的底部居中。
  private var barOrigin: NSPoint?

  init(controlBar: AgentHostTerminalControlBar, hostView: NSView, focusTerminal: @escaping @MainActor () -> Void) {
    self.controlBar = controlBar
    self.hostView = hostView
    self.focusTerminal = focusTerminal
    super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
    hostView.removeFromSuperview()
    hostView.translatesAutoresizingMaskIntoConstraints = true
    controlBar.translatesAutoresizingMaskIntoConstraints = true
    controlOverlay.translatesAutoresizingMaskIntoConstraints = true
    addSubview(hostView)
    addSubview(controlOverlay)
    addSubview(controlBar)
    controlBar.onDrag = { [weak self] delta in self?.moveBar(by: delta) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 打开或撤掉遮罩，并搬动键盘焦点：盖上时把焦点从终端移到遮罩上（按键被吞掉），
  /// 撤掉时若焦点还在遮罩上就还给终端，用户不用再点一下才能打字。
  func setAgentControlling(_ active: Bool) {
    guard active != controlOverlay.isActive else { return }
    if active {
      // 先生效再抢焦点：遮罩只有生效时才接受第一响应者。
      controlOverlay.setActive(true)
      if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: hostView) {
        window?.makeFirstResponder(controlOverlay)
      }
    } else {
      let overlayHadFocus = window?.firstResponder === controlOverlay
      controlOverlay.setActive(false)
      if overlayHadFocus { focusTerminal() }
    }
  }

  /// 终端占满窗口并留出边框宽度；胶囊浮在终端上，默认底部居中，拖过之后保持用户的位置，
  /// 窗口缩小时收回到可见范围内。胶囊使用固定首选宽度，窗口窄时两侧各留 8pt。
  override func layout() {
    super.layout()
    let inset: CGFloat = 2
    hostView.frame = bounds.insetBy(dx: inset, dy: inset)
    controlOverlay.frame = hostView.frame
    let barWidth = min(AgentHostTerminalControlBar.preferredWidth, max(bounds.width - Self.barEdgeMargin * 2, 0))
    let size = NSSize(width: barWidth, height: AgentHostTerminalControlBar.height)
    let defaultOrigin = NSPoint(x: ((bounds.width - barWidth) / 2).rounded(), y: Self.barBottomMargin)
    let origin = clampedBarOrigin(barOrigin ?? defaultOrigin, size: size)
    if barOrigin != nil { barOrigin = origin }
    controlBar.frame = NSRect(origin: origin, size: size)
  }

  /// 拖动胶囊：在当前位置上加位移，限制在容器四边以内。
  private func moveBar(by delta: CGSize) {
    let current = controlBar.frame.origin
    barOrigin = clampedBarOrigin(
      NSPoint(x: current.x + delta.width, y: current.y + delta.height), size: controlBar.frame.size)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private func clampedBarOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
    let margin = Self.barEdgeMargin
    let maxX = max(bounds.width - size.width - margin, margin)
    let maxY = max(bounds.height - size.height - margin, margin)
    return NSPoint(x: min(max(origin.x, margin), maxX).rounded(), y: min(max(origin.y, margin), maxY).rounded())
  }
}
