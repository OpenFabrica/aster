// Pane 底部的 agent 主机终端停靠区：28pt 头部（每台主机一个标签，右侧「弹出为独立窗口」「收起」）
// 加选中终端的内容（终端 + 遮罩 + 控制胶囊）。头部空白处上下拖动调高度。
// 用 frame 布局：终端内容是 frame 挂载的长期复用视图，不混用约束（同 AgentHostTerminalContentView）。
// 停靠区自己吞掉点击，不冒泡到 Pane 宿主去激活 Pane、抢焦点；拖放一律拒收，
// 文件和文本不会粘进 agent 自己的终端，也不会拆出新 Pane。
import AppKit
import AsterCore

/// 停靠区视图。由 `AgentHostPaneDocks` 创建和驱动，工作区只负责把它装进 Pane 底部。
@MainActor
final class AgentHostPaneDockView: NSView {
  /// 头部高度；收起后停靠区只剩这一条。
  static let headerHeight: CGFloat = 28
  /// 单个标签的最大与最小宽度：主机名太长时截断，标签太多时等比压缩。
  private static let maximumTabWidth: CGFloat = 180
  private static let minimumTabWidth: CGFloat = 48
  private static let buttonSize = NSSize(width: 24, height: 22)

  /// 头部的一个主机标签。
  struct Tab: Equatable {
    var terminalID: String
    /// 标签文字（主机名）。
    var title: String
    /// 悬停提示（调用方 → 主机）。
    var toolTip: String
    var tone: AgentHostTerminalControlBar.Tone
  }

  /// 点了某个标签（参数是终端 ID）。
  var onSelect: ((String) -> Void)?
  /// 点了「收起 / 展开」。
  var onToggleCollapsed: (() -> Void)?
  /// 点了「弹出为独立窗口」。
  var onPopOut: (() -> Void)?
  /// 拖头部调高度：参数是想要的高度占所在 Pane 高度的比例，由注册表夹紧。
  var onResize: ((CGFloat) -> Void)?

  private(set) var tabs: [Tab] = []
  private(set) var selectedID: String?
  private(set) var isCollapsed = false
  /// 按位置复用的标签按钮；按钮 i 永远对应 `tabs[i]`。
  private var tabButtons: [AgentHostPaneDockTabButton] = []
  private lazy var popOutButton = IconHoverButton(
    symbol: "macwindow.on.rectangle", accessibilityDescription: L("弹出为独立窗口")
  ) { [weak self] in self?.onPopOut?() }
  private lazy var collapseButton = IconHoverButton(
    symbol: "chevron.down", accessibilityDescription: L("收起")
  ) { [weak self] in self?.onToggleCollapsed?() }
  /// 正在显示的终端内容（选中且展开时）。
  private weak var displayedContent: NSView?
  /// 最后一个标签的右边界，头部空白（可拖动调高度）从这里开始。
  private var tabsMaxX: CGFloat = 0
  /// 头部拖动的起点：窗口坐标 y 与当时的停靠区高度。
  private var resizeStart: (y: CGFloat, height: CGFloat)?

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
    popOutButton.toolTip = L("弹出为独立窗口")
    collapseButton.toolTip = L("收起")
    addSubview(popOutButton)
    addSubview(collapseButton)
    // 与 Pane 宿主注册相同的类型：拖到停靠区上的东西停在这里被拒收，不会再往上交给 Pane 宿主。
    registerForDraggedTypes([.fileURL, .URL, .string])
    setAccessibilityRole(.group)
    setAccessibilityLabel(L("Agent 主机终端"))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 刷新标签、选中项、收起状态与显示的内容。`content` 是选中终端的内容视图，收起时不挂进来：
  /// 没选中的终端也都不在视图树里，surface 照常运行，按键只会进看得见的那个。
  func apply(tabs: [Tab], selectedID: String?, content: NSView?, collapsed: Bool) {
    self.tabs = tabs
    self.selectedID = selectedID
    isCollapsed = collapsed
    syncTabButtons()
    let collapseLabel = collapsed ? L("展开") : L("收起")
    collapseButton.setSymbol(collapsed ? "chevron.up" : "chevron.down", accessibilityDescription: collapseLabel)
    collapseButton.toolTip = collapseLabel
    let shown = collapsed ? nil : content
    if displayedContent !== shown {
      // 旧内容可能已被搬去浮窗：只摘还挂在这里的，不能把它从浮窗里扯出来。
      if let old = displayedContent, old.superview === self { old.removeFromSuperview() }
      if let shown {
        shown.translatesAutoresizingMaskIntoConstraints = true
        addSubview(shown, positioned: .below, relativeTo: nil)
      }
      displayedContent = shown
    }
    needsLayout = true
    window?.invalidateCursorRects(for: self)
  }

  /// 按位置增删、更新标签按钮，数量不变时原地改文字和颜色，不重建。
  private func syncTabButtons() {
    while tabButtons.count > tabs.count { tabButtons.removeLast().removeFromSuperview() }
    while tabButtons.count < tabs.count {
      let index = tabButtons.count
      let button = AgentHostPaneDockTabButton { [weak self] in self?.selectTab(at: index) }
      addSubview(button)
      tabButtons.append(button)
    }
    for (button, tab) in zip(tabButtons, tabs) {
      button.label = tab.title
      button.toolTip = tab.toolTip
      button.tone = tab.tone
      button.isSelectedTab = tab.terminalID == selectedID
    }
  }

  private func selectTab(at index: Int) {
    guard tabs.indices.contains(index) else { return }
    onSelect?(tabs[index].terminalID)
  }

  // MARK: - 布局与绘制

  /// 头部贴顶：标签从左往右排，放不下时等比压缩；两个图标按钮靠右。内容占头部以下的全部空间。
  override func layout() {
    super.layout()
    let headerY = bounds.height - Self.headerHeight
    let size = Self.buttonSize
    let buttonY = headerY + ((Self.headerHeight - size.height) / 2).rounded()
    collapseButton.frame = NSRect(origin: NSPoint(x: bounds.width - 6 - size.width, y: buttonY), size: size)
    popOutButton.frame = NSRect(origin: NSPoint(x: collapseButton.frame.minX - 2 - size.width, y: buttonY), size: size)

    let spacing: CGFloat = 2
    let available = max(popOutButton.frame.minX - 8 - 6, 0)
    let preferred = tabButtons.map { min($0.intrinsicContentSize.width, Self.maximumTabWidth) }
    let total = preferred.reduce(0, +) + spacing * CGFloat(max(tabButtons.count - 1, 0))
    let scale = total > available && total > 0 ? available / total : 1
    var x: CGFloat = 6
    for (button, width) in zip(tabButtons, preferred) {
      let fitted = max((width * scale).rounded(.down), Self.minimumTabWidth)
      button.frame = NSRect(x: x, y: headerY + 3, width: fitted, height: Self.headerHeight - 6)
      x += fitted + spacing
    }
    tabsMaxX = x
    displayedContent?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(headerY, 0))
  }

  /// 外层约束改尺寸时重新摆放头部与内容。
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  /// 背景与顶边分隔线在绘制时解析动态颜色：停靠区是长期视图，主题切换后不能停在旧颜色上。
  override func draw(_ dirtyRect: NSRect) {
    AsterTheme.panel.setFill()
    bounds.fill()
    AsterTheme.hairline.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// 头部空白处显示上下调整光标；收起时不能调高度。
  override func resetCursorRects() {
    guard !isCollapsed, popOutButton.frame.minX > tabsMaxX else { return }
    addCursorRect(
      NSRect(x: tabsMaxX, y: bounds.height - Self.headerHeight, width: popOutButton.frame.minX - tabsMaxX,
        height: Self.headerHeight),
      cursor: .resizeUpDown)
  }

  // MARK: - 鼠标

  /// 吞掉点击：不冒泡到 Pane 宿主（它会激活 Pane，把焦点抢回 agent 自己的终端）。
  /// 展开时在头部空白处按下才开始调高度。
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !isCollapsed, point.y >= bounds.height - Self.headerHeight {
      resizeStart = (event.locationInWindow.y, bounds.height)
    } else {
      resizeStart = nil
    }
  }

  /// 往上拖变高、往下拖变矮；比例的夹紧与生效交给注册表。
  override func mouseDragged(with event: NSEvent) {
    guard let start = resizeStart, let paneHeight = superview?.bounds.height, paneHeight > 0 else { return }
    onResize?((start.height + event.locationInWindow.y - start.y) / paneHeight)
  }

  override func mouseUp(with event: NSEvent) { resizeStart = nil }
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}

  // MARK: - 拖放：一律拒收

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

/// 停靠区头部的主机标签：状态色点 + 主机名；选中时有浅底，悬停时加深文字。
@MainActor
final class AgentHostPaneDockTabButton: NSButton {
  private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
  private let handler: () -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false

  /// 标签文字（主机名）。
  var label = "" {
    didSet {
      guard label != oldValue else { return }
      invalidateIntrinsicContentSize()
      needsDisplay = true
      setAccessibilityLabel(label)
    }
  }
  var tone: AgentHostTerminalControlBar.Tone = .idle {
    didSet { if tone != oldValue { needsDisplay = true } }
  }
  var isSelectedTab = false {
    didSet { if isSelectedTab != oldValue { needsDisplay = true } }
  }

  init(handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    title = ""
    isBordered = false
    target = self
    action = #selector(invoke)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 色点 + 文字 + 两侧留白。
  override var intrinsicContentSize: NSSize {
    let text = (label as NSString).size(withAttributes: [.font: Self.font])
    return NSSize(width: ceil(text.width) + 30, height: 22)
  }

  /// 状态色点：运行中蓝、等输入橙、空闲绿、已接管黄、已结束灰。
  static func dotColor(for tone: AgentHostTerminalControlBar.Tone) -> NSColor {
    switch tone {
    case .active: NSColor(srgbRed: 0.36, green: 0.60, blue: 1, alpha: 1)
    case .attention: .systemOrange
    case .idle: .systemGreen
    case .paused: .systemYellow
    case .ended: AsterTheme.tertiaryInk
    }
  }

  /// 自绘：动态颜色在绘制时按当前外观解析，主题切换后自动跟上。
  override func draw(_ dirtyRect: NSRect) {
    let emphasized = isSelectedTab || isHovering
    if emphasized {
      AsterTheme.ink.withAlphaComponent(isSelectedTab ? 0.10 : 0.06).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
    Self.dotColor(for: tone).setFill()
    NSBezierPath(ovalIn: NSRect(x: 9, y: (bounds.midY - 3).rounded(), width: 6, height: 6)).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font, .foregroundColor: emphasized ? AsterTheme.ink : AsterTheme.secondaryInk,
      .paragraphStyle: paragraph,
    ]
    let lineHeight = ceil((label as NSString).size(withAttributes: attributes).height)
    let textRect = NSRect(
      x: 21, y: ((bounds.height - lineHeight) / 2).rounded(), width: max(bounds.width - 29, 0), height: lineHeight)
    (label as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovering = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovering = false
    needsDisplay = true
  }

  @objc private func invoke() { handler() }
}
