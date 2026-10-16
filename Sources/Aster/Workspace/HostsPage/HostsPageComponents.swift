// 主机页的小部件：搜索框、胶囊按钮、分区标题与卡片网格。卡片本身见 `HostsPageCardView`。
import AppKit
import AsterCore

/// 主机页的配色。全部取自 `AsterTheme` 的动态色，跟随主题与明暗外观自动解析。
@MainActor
enum HostsPagePalette {
  /// 卡片底色：在页面底色上叠一层前景色，浅色主题略深、深色主题略浅，两种外观都分得出层次。
  static let card = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .foreground, appearance: appearance)
      .withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.06 : 0.035)
  }
  /// 卡片悬停底色。
  static let cardHover = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .foreground, appearance: appearance)
      .withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.11 : 0.07)
  }
  /// 输入框与胶囊按钮的静止底色。
  static let control = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .foreground, appearance: appearance)
      .withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.08 : 0.05)
  }
  /// 胶囊按钮悬停底色。
  static let controlHover = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .foreground, appearance: appearance).withAlphaComponent(0.12)
  }
}

// MARK: - 圆角底色视图

/// 只画一块圆角底色的视图。颜色在 `updateLayer` 里解析，切换明暗外观或主题后
/// 标记 `needsDisplay` 即可按新外观重画，不会冻结成创建时的 CGColor。
/// 不是 final：编辑面板的输入框与面板根视图在它上面加控件或键盘处理。
@MainActor
class HostsPageFilledView: NSView {
  var fillColor: NSColor {
    didSet { needsDisplay = true }
  }

  /// `cornerRadius` 为圆角半径。
  init(fillColor: NSColor, cornerRadius: CGFloat) {
    self.fillColor = fillColor
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = cornerRadius
    layer?.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// AppKit 调用时当前外观已是本视图的外观，动态色在这里解析才准确。
  override func updateLayer() {
    layer?.backgroundColor = fillColor.cgColor
  }
}

// MARK: - 胶囊按钮

/// 主机页工具栏的胶囊按钮：可带图标与文字，悬停加深底色。
///
/// 有 `menuProvider` 时在 mouseDown 弹出菜单（与侧栏工作区按钮一致），否则按普通按钮
/// 在松开时触发 `handler`。`showsBackground` 为 false 时静止态透明，只在悬停时显示底色。
@MainActor
final class HostsPagePillButton: NSButton {
  private let handler: (() -> Void)?
  private let menuProvider: (() -> NSMenu)?
  private let showsBackground: Bool
  private var tracking: NSTrackingArea?
  private var hovered = false {
    didSet { if hovered != oldValue { applyStyle() } }
  }

  /// 构建按钮；`title` 为空时只显示图标。
  init(
    title: String, symbol: String?, showsBackground: Bool = true,
    handler: (() -> Void)? = nil, menuProvider: (() -> NSMenu)? = nil
  ) {
    self.handler = handler
    self.menuProvider = menuProvider
    self.showsBackground = showsBackground
    super.init(frame: .zero)
    self.title = title
    font = NSFont.interface(ofSize: 12.5, weight: .medium)
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)?
        .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
      imagePosition = title.isEmpty ? .imageOnly : .imageLeading
      imageHugsTitle = true
    }
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    contentTintColor = AsterTheme.ink
    target = self
    action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: InterfaceScale.length(30)).isActive = true
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 文字两侧留出内边距；只有图标时保持正方形。
  override var intrinsicContentSize: NSSize {
    let base = super.intrinsicContentSize
    let height = InterfaceScale.length(30)
    return title.isEmpty ? NSSize(width: height, height: height) : NSSize(width: base.width + 22, height: height)
  }

  /// 菜单按钮在按下时弹出菜单，菜单关闭后恢复样式。
  override func mouseDown(with event: NSEvent) {
    guard let menuProvider else {
      super.mouseDown(with: event)
      return
    }
    layer?.backgroundColor = HostsPagePalette.controlHover.cgColor
    let origin = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
    menuProvider().popUp(positioning: nil, at: origin, in: self)
    applyStyle()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  /// 外观切换后 CGColor 要按新外观重新解析。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyStyle()
  }

  /// 按悬停状态设置底色；CGColor 在当前外观上下文里解析。
  private func applyStyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let color: NSColor =
        hovered ? HostsPagePalette.controlHover : (showsBackground ? HostsPagePalette.control : .clear)
      layer?.backgroundColor = color.cgColor
    }
  }

  @objc private func invoke() { handler?() }
}

// MARK: - 分区标题

/// 「分组」「主机」分区标题。
@MainActor
func makeHostsPageSectionTitle(_ text: String, identifier: String) -> NSTextField {
  let label = makeLabel(text, size: 13, weight: .semibold, color: AsterTheme.ink)
  label.identifier = NSUserInterfaceItemIdentifier(identifier)
  return label
}

// MARK: - 卡片网格

/// 等宽多列卡片网格。列数随宽度变化，高度随行数变化。
///
/// 用手动 frame 排布而不是嵌套 NSStackView：列数要按实际宽度现算，栈视图做不到「一行放几个」。
/// 自身高度通过一条约束交给外层滚动文档，宽度变化时在 `layout()` 里更新。
@MainActor
final class HostsPageGridView: NSView {
  /// 卡片最小宽度；窄于它就减少列数。
  static let minimumCardWidth: CGFloat = 230
  /// 最多几列（宽窗口下与 Termius 一致为 3 列）。
  static let maximumColumns = 3
  static let spacing: CGFloat = 14

  /// 列表模式固定一列。
  var isListMode = false {
    didSet { if isListMode != oldValue { needsLayout = true } }
  }
  private(set) var items: [NSView] = []
  private let rowHeight: CGFloat
  private var heightConstraint: NSLayoutConstraint!

  override var isFlipped: Bool { true }

  /// `rowHeight` 是每张卡片的高度（已按界面字号缩放）。
  init(rowHeight: CGFloat) {
    self.rowHeight = rowHeight
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    heightConstraint.isActive = true
  }

  required init?(coder: NSCoder) { nil }

  /// 某个宽度下的列数：在最小卡片宽度内尽量多放，但不超过上限，至少一列。纯函数，便于测试。
  static func columns(forWidth width: CGFloat, listMode: Bool) -> Int {
    guard !listMode else { return 1 }
    let fitting = Int((width + spacing) / (minimumCardWidth + spacing))
    return min(max(fitting, 1), maximumColumns)
  }

  /// 替换全部卡片。
  func setItems(_ views: [NSView]) {
    items.forEach { $0.removeFromSuperview() }
    items = views
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
    }
    needsLayout = true
  }

  /// 按当前宽度排布卡片，并把总高度写回约束；只有高度真的变化才改约束，避免布局循环。
  override func layout() {
    super.layout()
    let width = bounds.width
    let columns = Self.columns(forWidth: width, listMode: isListMode)
    let cardWidth = max((width - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns), 0)
    for (index, view) in items.enumerated() {
      let row = index / columns
      let column = index % columns
      view.frame = NSRect(
        x: CGFloat(column) * (cardWidth + Self.spacing),
        y: CGFloat(row) * (rowHeight + Self.spacing),
        width: cardWidth, height: rowHeight
      ).integral
    }
    let rows = (items.count + columns - 1) / columns
    let height = rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * Self.spacing
    if heightConstraint.constant != height { heightConstraint.constant = height }
  }
}
