// agent 主机终端的浮动窗口：用户看着 agent 在真实 SSH 终端里干活，随时可以接手打字、
// 中断命令、暂停 agent 或关闭终端。面板不抢焦点（nonactivating），用户点进终端才成为 key。
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
    var togglePause: @MainActor () -> Void
    var closeTerminal: @MainActor () -> Void
  }

  /// 新窗口相对上一个的错位，多个终端不完全重叠。
  private static var cascadePoint = NSPoint.zero

  private weak var terminal: AgentHostTerminal?
  private let panel: AgentHostTerminalPanel
  private let actions: Actions
  private let statusLabel = NSTextField(labelWithString: "")
  private let interruptButton = NSButton()
  private let pauseButton = NSButton()

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
    switch terminal.state {
    case .connecting: statusLabel.stringValue = L("正在连接…")
    case .ready: statusLabel.stringValue = terminal.isPaused ? L("空闲 · agent 已暂停") : L("空闲")
    case .busy: statusLabel.stringValue = L("正在运行：\(command)")
    case .needsInput: statusLabel.stringValue = L("等待你的输入：请直接在下面的终端里回答")
    case .ended: statusLabel.stringValue = L("终端已结束")
    }
    statusLabel.textColor = terminal.state == .needsInput ? .systemOrange : .labelColor
    interruptButton.isEnabled = terminal.state == .busy || terminal.state == .needsInput
    pauseButton.title = terminal.isPaused ? L("恢复 agent") : L("暂停 agent")
    pauseButton.isEnabled = terminal.state != .ended
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
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    configure(interruptButton, title: L("中断"), action: #selector(interruptClicked))
    configure(pauseButton, title: L("暂停 agent"), action: #selector(pauseClicked))
    let closeButton = NSButton()
    configure(closeButton, title: L("关闭终端"), action: #selector(closeClicked))
    let header = NSStackView(views: [statusLabel, NSView(), interruptButton, pauseButton, closeButton])
    header.orientation = .horizontal
    header.spacing = 8
    header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

    let container = AgentHostTerminalContentView(header: header, hostView: hostView)
    container.wantsLayer = true
    // 强调色边框：一眼认出这是 agent 在操作的终端，不是自己的工作区。
    container.layer?.borderColor = NSColor.controlAccentColor.cgColor
    container.layer?.borderWidth = 2
    return container
  }

  private func configure(_ button: NSButton, title: String, action: Selector) {
    button.title = title
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.target = self
    button.action = action
  }

  @objc private func interruptClicked() { actions.interrupt() }
  @objc private func pauseClicked() { actions.togglePause() }
  @objc private func closeClicked() { actions.closeTerminal() }
}

/// 允许成为 key（用户要在里面打字），但不成为 main，不改变工作区窗口的主窗口身份。
@MainActor
private final class AgentHostTerminalPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// 头部 + 终端的容器。用 frame 布局而不是约束：终端宿主是 frame 挂载的长期复用视图，
/// 与 Quick Terminal 一样避免混用约束（见 QuickTerminalController.installTerminalHost）。
@MainActor
private final class AgentHostTerminalContentView: NSView {
  static let headerHeight: CGFloat = 34
  private let header: NSView
  private let hostView: NSView

  init(header: NSView, hostView: NSView) {
    self.header = header
    self.hostView = hostView
    super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
    hostView.removeFromSuperview()
    hostView.translatesAutoresizingMaskIntoConstraints = true
    header.translatesAutoresizingMaskIntoConstraints = true
    addSubview(header)
    addSubview(hostView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 头部贴顶，终端占满其余部分并留出边框宽度。
  override func layout() {
    super.layout()
    let inset: CGFloat = 2
    header.frame = NSRect(x: 0, y: bounds.height - Self.headerHeight, width: bounds.width, height: Self.headerHeight)
    hostView.frame = NSRect(
      x: inset, y: inset, width: max(bounds.width - inset * 2, 0),
      height: max(bounds.height - Self.headerHeight - inset, 0))
  }
}
