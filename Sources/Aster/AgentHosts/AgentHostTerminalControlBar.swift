// agent 主机终端的控制胶囊：参照 ego lite 的 agent 控制条，深色圆角胶囊里放拖动把手、
// 状态图标、两行文字（任务 / 状态）与胶囊按钮。默认浮在终端底部居中，按住按钮以外的地方
// 可以拖到别处。无论 App 是浅色还是深色外观都固定用深色，一眼认出「这里是 agent 在控制」。
import AppKit
import AsterCore

/// 控制胶囊。由 `AgentHostTerminalPanelController` 填内容、接按钮动作。
@MainActor
final class AgentHostTerminalControlBar: NSView {
  /// 状态语气：决定状态文字颜色与左侧图标。
  enum Tone: Equatable {
    /// 正在连接或运行命令：蓝色文字 + 转圈。
    case active
    /// 等用户在终端里输入：橙色文字。
    case attention
    /// 空闲。
    case idle
    /// agent 已暂停。
    case paused
    /// 终端已结束。
    case ended
  }

  static let height: CGFloat = 44
  /// 常规窗口保持固定宽度；仅随可用窗口宽度收窄，不让命令或主机名改变位置。
  static let preferredWidth: CGFloat = 520

  let interruptButton = AgentHostPillButton(style: .normal)
  let pauseButton = AgentHostPillButton(style: .normal)
  let closeButton = AgentHostPillButton(style: .destructive)

  private let grip = AgentHostTerminalGripView()
  private let iconSlot = NSView()
  private var pauseButtonWidth: CGFloat = 0
  private let spinner = NSProgressIndicator()
  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  /// 上一次拖动事件在窗口里的位置；nil 表示当前没有在拖。
  private var dragAnchor: NSPoint?
  /// 用户拖动胶囊时回报位移（窗口坐标增量），由容器负责移动并限制在终端范围内。
  var onDrag: ((CGSize) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // 固定深色外观：按钮、转圈和文字都按深色渲染，不跟随浅色主题变白。
    appearance = NSAppearance(named: .darkAqua)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
    layer?.cornerRadius = Self.height / 2
    layer?.borderWidth = 1
    layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
    shadow = NSShadow()
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    buildLayout()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 更新两行文字与状态语气。
  func update(title: String, status: String, tone: Tone) {
    titleLabel.stringValue = title
    statusLabel.stringValue = status
    titleLabel.toolTip = title
    statusLabel.toolTip = status
    statusLabel.textColor = Self.statusColor(for: tone)
    let spinning = tone == .active
    spinner.isHidden = !spinning
    iconView.isHidden = spinning
    if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    iconView.image = Self.icon(for: tone)
    iconView.contentTintColor = Self.statusColor(for: tone)
    needsLayout = true
  }

  // MARK: - 拖动

  /// 按钮照常接收点击；胶囊上其余位置（文字、图标、空白）都归胶囊自己，用来拖动。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    var view: NSView? = hit
    while let current = view, current !== self {
      if current is NSButton { return hit }
      view = current.superview
    }
    return self
  }

  override func mouseDown(with event: NSEvent) { dragAnchor = event.locationInWindow }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor = dragAnchor else { return }
    let location = event.locationInWindow
    dragAnchor = location
    onDrag?(CGSize(width: location.x - anchor.x, height: location.y - anchor.y))
  }

  override func mouseUp(with event: NSEvent) { dragAnchor = nil }

  /// 胶囊不能拖动整个窗口，否则拖胶囊会变成拖面板。
  override var mouseDownCanMoveWindow: Bool { false }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

  // MARK: - 布局

  private func buildLayout() {
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    for view in [spinner, iconView] as [NSView] { iconSlot.addSubview(view) }

    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .white
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    for label in [titleLabel, statusLabel] {
      label.lineBreakMode = .byTruncatingTail
      label.maximumNumberOfLines = 1
    }
    // 两种操作文案共用同一宽度，接管切换时不挤动文字区和右侧按钮；按本地化文案测量。
    pauseButtonWidth = [L("接管"), L("交还 agent")].map {
      ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width) + 24
    }.max() ?? 0
    for view in [grip, iconSlot, titleLabel, statusLabel, interruptButton, pauseButton, closeButton] {
      addSubview(view)
    }
  }

  /// 与外层终端容器一样使用 frame 布局；按钮从右侧排起，文字只使用剩余宽度。
  /// 尺寸和位置在同一轮布局内确定，不依赖 Stack 的延迟 intrinsic size 刷新。
  override func layout() {
    super.layout()
    grip.frame = NSRect(x: 12, y: (bounds.height - 14) / 2, width: 6, height: 14)
    iconSlot.frame = NSRect(x: 26, y: (bounds.height - 20) / 2, width: 20, height: 20)
    spinner.frame = iconSlot.bounds
    iconView.frame = iconSlot.bounds

    var trailing = bounds.width - 8
    for button in [closeButton, pauseButton, interruptButton] {
      let width = button === pauseButton ? pauseButtonWidth : button.intrinsicContentSize.width
      button.frame = NSRect(x: trailing - width, y: (bounds.height - 28) / 2, width: width, height: 28)
      trailing = button.frame.minX - 6
    }
    let textX: CGFloat = 56
    let textWidth = max(interruptButton.frame.minX - 18 - textX, 0)
    let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
    let statusHeight = ceil(statusLabel.intrinsicContentSize.height)
    let textY = ((bounds.height - titleHeight - statusHeight - 1) / 2).rounded()
    statusLabel.frame = NSRect(x: textX, y: textY, width: textWidth, height: statusHeight)
    titleLabel.frame = NSRect(x: textX, y: textY + statusHeight + 1, width: textWidth, height: titleHeight)
  }

  // MARK: - 外观

  /// ego lite 的「Agent 正在控制」蓝。
  private static let activeBlue = NSColor(srgbRed: 0.36, green: 0.60, blue: 1, alpha: 1)

  private static func statusColor(for tone: Tone) -> NSColor {
    switch tone {
    case .active: activeBlue
    case .attention: .systemOrange
    case .idle: NSColor(white: 1, alpha: 0.62)
    case .paused: .systemYellow
    case .ended: NSColor(white: 1, alpha: 0.42)
    }
  }

  private static func icon(for tone: Tone) -> NSImage? {
    let name =
      switch tone {
      case .active: "circle.dotted"
      case .attention: "keyboard"
      case .idle: "terminal"
      case .paused: "pause.circle"
      case .ended: "stop.circle"
      }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)
  }
}

/// 胶囊左侧的拖动把手：两列三行小圆点。
@MainActor
private final class AgentHostTerminalGripView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 1, alpha: 0.35).setFill()
    for column in 0..<2 {
      for row in 0..<3 {
        let dot = NSRect(x: CGFloat(column) * 4, y: CGFloat(row) * 5 + 1, width: 2, height: 2)
        NSBezierPath(ovalIn: dot).fill()
      }
    }
  }
}

/// 控制胶囊里的圆角按钮：半透明白底、悬停加亮、按下更亮；危险动作用红字。
@MainActor
final class AgentHostPillButton: NSButton {
  enum Style {
    case normal
    case destructive
  }

  private let style: Style
  private var isHovering = false { didSet { updateLook() } }
  private var isPressed = false { didSet { updateLook() } }

  init(style: Style) {
    self.style = style
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .regularSquare
    wantsLayer = true
    layer?.cornerRadius = 8
    setButtonType(.momentaryChange)
    updateLook()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var title: String {
    didSet { applyTitle() }
  }

  override var isEnabled: Bool {
    didSet { updateLook() }
  }

  /// 文字两侧留白，高度固定 28pt。
  override var intrinsicContentSize: NSSize {
    let size = attributedTitle.size()
    return NSSize(width: ceil(size.width) + 24, height: 28)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    // 面板是 nonactivating，App 不在前台时也要有悬停反馈，所以用 activeAlways。
    addTrackingArea(
      NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { isHovering = true }
  override func mouseExited(with event: NSEvent) { isHovering = false }

  /// `super.mouseDown` 会同步跑完点击追踪循环，前后切换按下态即可。
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    isPressed = true
    super.mouseDown(with: event)
    isPressed = false
  }

  private func applyTitle() {
    let color: NSColor =
      switch style {
      case .normal: .white
      case .destructive: NSColor(srgbRed: 1, green: 0.42, blue: 0.37, alpha: 1)
      }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
    invalidateIntrinsicContentSize()
  }

  private func updateLook() {
    let alpha: CGFloat = isPressed ? 0.28 : (isHovering && isEnabled ? 0.2 : 0.12)
    layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
    alphaValue = isEnabled ? 1 : 0.4
  }
}
