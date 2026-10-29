// 界面扩展 `pane.header` 的原生视图：终端 Pane 顶条上的一组图标按钮，排在实时画面、缩放、关闭按钮左边，
// 与它们一起在指针靠近 Pane 顶边时淡入。只放图标、最多 3 个，不占终端行数；隐藏时不拦截终端的点击。
// 由 WorkspaceExtensionHost 按 Pane 长期持有，工作区整树重建时只换父视图；内容变化只调 `apply(segments:)`。
import AppKit
import AsterCore

/// Pane 顶条上的插件图标组。只在主线程使用。
@MainActor
final class ToolPaneHeaderView: NSView {
  /// 最多显示几个图标：顶条很窄，还要给拖动把手和自带按钮留位置。
  static let maximumButtons = 3

  /// 点了带动作的项目（段 id、项目）。
  var onItem: ((_ segmentID: String, _ item: ToolBarItem) -> Void)?
  /// 点了失败段：重跑。
  var onRetry: ((_ segmentID: String) -> Void)?
  /// 点了「需要授权」。
  var onApprove: ((_ segmentID: String) -> Void)?
  /// 当前主题；nil 时用 `AsterTheme` 动态色。
  var themeProvider: (() -> TerminalTheme?)?
  /// 与顶条其它控件同步淡入淡出；只由 Pane 宿主的 `updateChromeReveal` 写入。
  var isRevealed = false {
    didSet {
      guard oldValue != isRevealed else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        context.allowsImplicitAnimation = true
        animator().alphaValue = isRevealed ? 1 : 0
      }
    }
  }

  private(set) var segments: [ToolBarSegment] = []
  /// 按「段 id + 项目 id（没有就用序号）」复用的按钮：跨刷新保持悬停态。
  private var buttons: [String: ToolBarItemButton] = [:]
  /// 当前显示的按钮，从左到右。
  private(set) var visibleButtons: [ToolBarItemButton] = []
  private var widthConstraint: NSLayoutConstraint!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = NSUserInterfaceItemIdentifier("tool-bar-\(ToolViewSlot.paneHeader.rawValue)")
    translatesAutoresizingMaskIntoConstraints = false
    alphaValue = 0
    widthConstraint = widthAnchor.constraint(equalToConstant: 0)
    widthConstraint.isActive = true
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel(L("插件状态条"))
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 换上全部段：按段与项目的顺序取前 3 个有图标的按钮。文字只进提示（没有 tooltip 时用文字代替）。
  func apply(segments newSegments: [ToolBarSegment]) {
    segments = newSegments
    var reused: [String: ToolBarItemButton] = [:]
    var shown: [ToolBarItemButton] = []
    for segment in newSegments where !segment.isEmpty {
      for (key, content) in ToolBarView.contents(of: segment) where shown.count < Self.maximumButtons {
        let button = buttons[key] ?? makeButton()
        button.configure(Self.iconOnly(content))
        button.onPress = pressHandler(segmentID: segment.id, content: content)
        reused[key] = button
        if button.hasContent { shown.append(button) }
      }
    }
    for (key, button) in buttons where reused[key] == nil { button.removeFromSuperview() }
    buttons = reused
    visibleButtons = shown
    for button in buttons.values { button.isHidden = !shown.contains { $0 === button } }
    refreshAppearance()
    needsLayout = true
    widthConstraint.constant = shown.reduce(0) { $0 + ceil($1.intrinsicContentSize.width) }
  }

  /// 顶条上的项目内容：文字不显示，没有 tooltip 时把文字放进提示，悬停仍能看到。
  private static func iconOnly(_ content: ToolBarItemButton.Content) -> ToolBarItemButton.Content {
    guard case .item(var item) = content else { return content }
    if item.tooltip?.isEmpty ?? true { item.tooltip = item.text }
    return .item(item)
  }

  /// 按钮点击的去向。没有动作的项目只是展示。
  private func pressHandler(segmentID: String, content: ToolBarItemButton.Content) -> (() -> Void)? {
    switch content {
    case .item(let item):
      guard item.action != nil else { return nil }
      return { [weak self] in self?.onItem?(segmentID, item) }
    case .failure: return { [weak self] in self?.onRetry?(segmentID) }
    case .approval: return { [weak self] in self?.onApprove?(segmentID) }
    }
  }

  /// 新按钮只显示图标。
  private func makeButton() -> ToolBarItemButton {
    let button = ToolBarItemButton()
    button.showsLabel = false
    addSubview(button)
    return button
  }

  /// 主题或外观变了：重新解析颜色并推给每个按钮。
  func refreshAppearance() {
    let palette = ToolBarPalette.resolve(theme: themeProvider?())
    for button in buttons.values { button.palette = palette }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  /// 从左到右紧挨着排，高度占满（= 顶条感应带高度）。
  override func layout() {
    super.layout()
    var x: CGFloat = 0
    for button in visibleButtons {
      let width = ceil(button.intrinsicContentSize.width)
      button.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
      x += width
    }
  }

  /// 隐藏时不参与命中：图标浮在终端上方，看不见时点击必须落到终端。
  override func hitTest(_ point: NSPoint) -> NSView? {
    isRevealed ? super.hitTest(point) : nil
  }
}
