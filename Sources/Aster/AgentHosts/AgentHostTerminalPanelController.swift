// agent 主机终端的独立浮窗外壳。内容（终端 + 遮罩 + 控制胶囊）由 `AgentHostTerminalPresenter`
// 在浮窗与 Pane 停靠区之间搬动；浮窗只负责装内容、显示 / 隐藏、标题，以及标题栏右侧的「停靠到 Pane」。
// 面板不抢焦点（nonactivating），用户点进终端或点「接管」才成为 key。
import AppKit
import AsterCore

/// 每个终端一个浮窗。创建后一直留着当停车位：停靠时不显示，内容搬走。
@MainActor
final class AgentHostTerminalPanelController: NSObject, NSWindowDelegate {
  /// 新窗口相对上一个的错位，多个终端不完全重叠。
  private static var cascadePoint = NSPoint.zero

  private let panel: AgentHostTerminalPanel
  /// 面板固定的 contentView；内容作为它的子视图进出，面板的 contentView 本身从不更换。
  private let container = NSView()
  private let dockAccessory = NSTitlebarAccessoryViewController()
  /// 标题栏关闭时能否真的关窗（终端已结束）；否则只隐藏，终端照常运行。
  var allowsClose: () -> Bool = { false }
  /// 用户点了标题栏的「停靠到 Pane」。
  var onDock: (() -> Void)?

  init(preferences: AppPreferences) {
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
    panel.contentView = container
    installDockButton()
    panel.center()
    Self.cascadePoint = panel.cascadeTopLeft(from: Self.cascadePoint)
  }

  /// 浮窗本身；键盘归属判断与测试用。
  var window: NSWindow { panel }

  /// 窗口标题，例如「Claude Code → prod-db (deploy@10.0.0.5:22)」。
  var title: String {
    get { panel.title }
    set { panel.title = newValue }
  }

  /// 「停靠到 Pane」按钮是否显示；测试用。
  var isDockAvailable: Bool { !dockAccessory.isHidden }

  /// 装进内容并立即布局一次。Ghostty surface 要等终端视图进了窗口且尺寸非零才创建；
  /// 面板从没显示过也算有窗口，所以停靠模式下（浮窗不显示）SSH 也能马上连上。
  func install(_ content: NSView) {
    content.translatesAutoresizingMaskIntoConstraints = true
    content.autoresizingMask = [.width, .height]
    content.frame = container.bounds
    container.addSubview(content)
    container.layoutSubtreeIfNeeded()
  }

  /// 显示（不抢焦点）。
  func show() { panel.orderFrontRegardless() }
  func hide() { panel.orderOut(nil) }
  func makeKey() { panel.makeKey() }
  /// 同点标题栏关闭按钮。
  func performClose() { panel.performClose(nil) }

  func close() {
    panel.delegate = nil
    panel.orderOut(nil)
    panel.close()
  }

  /// 「停靠到 Pane」只在调用方 Pane 还在时显示。
  func setDockAvailable(_ available: Bool) {
    guard dockAccessory.isHidden == available else { return }
    dockAccessory.isHidden = !available
  }

  /// 标题栏关闭只隐藏面板，终端照常运行；「窗口 → Agent 终端」可以找回。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if allowsClose() { return true }
    panel.orderOut(nil)
    return false
  }

  /// 标题栏右侧的「停靠到 Pane」按钮，默认隐藏。
  private func installDockButton() {
    let button = NSButton(title: L("停靠到 Pane"), target: self, action: #selector(dockClicked))
    button.bezelStyle = .accessoryBarAction
    button.controlSize = .small
    button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    button.image = NSImage(systemSymbolName: "rectangle.bottomhalf.inset.filled", accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.toolTip = L("停靠到 Pane")
    let size = button.fittingSize
    let holder = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 12, height: 28))
    button.frame = NSRect(
      x: 4, y: ((holder.bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    holder.addSubview(button)
    dockAccessory.view = holder
    dockAccessory.layoutAttribute = .trailing
    // 先挂进标题栏再隐藏：挂之前设的 isHidden 会被 AppKit 忽略，按钮照样显示，
    // 而 setDockAvailable(false) 看到 isHidden 已是 true 就不再处理，结果没有 Pane 也露出一个点了没反应的按钮。
    panel.addTitlebarAccessoryViewController(dockAccessory)
    dockAccessory.isHidden = true
  }

  @objc private func dockClicked() { onDock?() }
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
    // 强调色边框：一眼认出这是 agent 在操作的终端，不是自己的工作区。浮窗与停靠区里一致。
    wantsLayer = true
    layer?.borderWidth = 2
    applyBorderColor()
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

  /// agent 正在干活（连接中、命令运行中）时遮罩光晕呼吸，其余时候静止。
  func setAgentWorking(_ working: Bool) {
    controlOverlay.isBreathing = working
  }

  /// 边框颜色在赋值时就冻结成 CGColor，外观或强调色变化后重新解析。
  private func applyBorderColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyBorderColor()
  }

  /// 在浮窗（autoresizing）和停靠区（父视图设 frame）里改尺寸时都重新摆放子视图。
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  /// 终端占满容器（浮窗或停靠区）并留出边框宽度；胶囊浮在终端上，默认底部居中，拖过之后保持用户的位置，
  /// 容器缩小时收回到可见范围内。胶囊使用固定首选宽度，窗口窄时两侧各留 8pt。
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
