// `sidebar.section` 的 bar：纵向列表，每项一行（24pt，随界面字号缩放），最多 `ToolBarProtocol.listItemLimit` 项。
// 项目、失败段与「需要授权」段的内容与点击去向和横条 ToolBarView 一致；没有项目时隐藏且高度归零。
import AppKit
import AsterCore

/// 侧栏里一个 bar 视图的项目列表。只在主线程使用。
@MainActor
final class ToolBarListView: NSView {
  /// 行高（点，未缩放）。
  static let rowHeight: CGFloat = 24

  /// 点了带动作的项目（段 id、项目）。
  var onItem: ((_ segmentID: String, _ item: ToolBarItem) -> Void)?
  /// 点了失败行：重跑。
  var onRetry: ((_ segmentID: String) -> Void)?
  /// 点了「需要授权」。
  var onApprove: ((_ segmentID: String) -> Void)?
  /// 当前主题；nil 时用 `AsterTheme` 动态色。
  var themeProvider: (() -> TerminalTheme?)?
  /// 行左右内边距；侧栏按 eyebrow 对齐后设置。
  var horizontalInset: CGFloat = 0 {
    didSet { needsLayout = true }
  }

  private(set) var segment: ToolBarSegment?
  /// 按复用键保存的按钮：跨刷新保持悬停态。
  private var buttons: [String: ToolBarItemButton] = [:]
  /// 当前显示的行，按脚本输出顺序。
  private(set) var rows: [ToolBarItemButton] = []
  private var heightConstraint: NSLayoutConstraint!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    heightConstraint.isActive = true
    setAccessibilityRole(.list)
    setAccessibilityLabel(L("插件状态条"))
    isHidden = true
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  /// 换上这一段的内容；按钮按键复用，超过列表上限的截掉（解析时已按上限截断，这里兜底）。
  func apply(segment newSegment: ToolBarSegment?) {
    segment = newSegment
    var reused: [String: ToolBarItemButton] = [:]
    rows = []
    let contents = newSegment.map(ToolBarView.contents(of:)) ?? []
    for (key, content) in contents.prefix(ToolBarProtocol.listItemLimit) {
      let button = buttons[key] ?? makeButton()
      button.configure(content)
      button.onPress = newSegment.flatMap { pressHandler(segmentID: $0.id, content: content) }
      reused[key] = button
      if button.hasContent {
        button.isHidden = false
        rows.append(button)
      } else {
        button.isHidden = true
      }
    }
    for (key, button) in buttons where reused[key] == nil { button.removeFromSuperview() }
    buttons = reused
    isHidden = rows.isEmpty
    heightConstraint.constant = CGFloat(rows.count) * InterfaceScale.length(Self.rowHeight)
    refreshAppearance()
    needsLayout = true
  }

  /// 点击去向，与横条相同：项目执行动作，失败行重跑，授权行弹确认；没有动作的项目只展示。
  private func pressHandler(segmentID: String, content: ToolBarItemButton.Content) -> (() -> Void)? {
    switch content {
    case .item(let item):
      guard item.action != nil else { return nil }
      return { [weak self] in self?.onItem?(segmentID, item) }
    case .failure: return { [weak self] in self?.onRetry?(segmentID) }
    case .approval: return { [weak self] in self?.onApprove?(segmentID) }
    }
  }

  /// 新按钮挂进视图树。
  private func makeButton() -> ToolBarItemButton {
    let button = ToolBarItemButton()
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

  /// 每行占满宽度（减去左右内边距），自上而下排；行内按钮高度比行高少 2pt，悬停底色不贴边。
  override func layout() {
    super.layout()
    let rowHeight = InterfaceScale.length(Self.rowHeight)
    let inset = InterfaceScale.length(1)
    let width = max(0, bounds.width - horizontalInset * 2)
    for (index, button) in rows.enumerated() {
      button.frame = NSRect(
        x: horizontalInset, y: CGFloat(index) * rowHeight + inset, width: width, height: rowHeight - inset * 2)
    }
  }
}
