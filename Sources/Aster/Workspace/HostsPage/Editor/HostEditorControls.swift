// 主机编辑面板的小部件：填充底色的输入框、多行输入、下拉、按钮、字段行与可折叠分区。
// 视觉与主机页搜索框一致（`HostsPagePalette.control` 圆角底色、无系统边框），颜色全部是动态色。
import AppKit
import AsterCore

/// 编辑面板的尺寸常量（默认字号档，使用处按需缩放）。
enum HostEditorMetrics {
  /// 面板宽度。
  static let panelWidth: CGFloat = 400
  /// 内容左右内边距。
  static let inset: CGFloat = 20
  /// 单行控件高度。
  static let controlHeight: CGFloat = 30
  /// 控件圆角。
  static let cornerRadius: CGFloat = 7
}

extension HostsPagePalette {
  /// 编辑面板底色：页面底色上再叠一层前景色，与卡片网格分出层次。
  static let drawer = NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return ThemeRuntime.shared.color(for: .window, appearance: appearance)
      .blended(withFraction: isDark ? 0.05 : 0.025, of: ThemeRuntime.shared.color(for: .foreground, appearance: appearance))
      ?? ThemeRuntime.shared.color(for: .window, appearance: appearance)
  }
  /// 端口转发规则卡片的底色。
  static let ruleCard = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .foreground, appearance: appearance)
      .withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.045 : 0.03)
  }
}

// MARK: - 输入控件

/// 圆角底色里放一个无边框单行输入框。`field` 是真正接收输入的控件。
@MainActor
final class HostEditorTextField: HostsPageFilledView {
  let field: NSTextField
  /// 右侧附加按钮（例如分组下拉），没有时为 nil。
  private(set) var accessory: NSView?

  /// `field` 可传入 `NSTokenField` 等子类；默认是普通输入框。
  init(placeholder: String, identifier: String, monospaced: Bool = false, field: NSTextField = NSTextField()) {
    self.field = field
    super.init(fillColor: HostsPagePalette.control, cornerRadius: HostEditorMetrics.cornerRadius)
    translatesAutoresizingMaskIntoConstraints = false
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = monospaced ? NSFont.interfaceMonospaced(ofSize: 12.5) : NSFont.interface(ofSize: 13)
    field.textColor = AsterTheme.ink
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    field.cell?.usesSingleLineMode = true
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: InterfaceScale.length(HostEditorMetrics.controlHeight)),
      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
      field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9).withPriority(.defaultHigh),
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  var stringValue: String {
    get { field.stringValue }
    set { field.stringValue = newValue }
  }

  /// 在输入框右侧放一个附加按钮，输入框让出位置。
  func setAccessory(_ view: NSView) {
    accessory?.removeFromSuperview()
    accessory = view
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    NSLayoutConstraint.activate([
      view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      view.centerYAnchor.constraint(equalTo: centerYAnchor),
      field.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: -4),
    ])
  }
}

/// 没有内容时画占位文字的多行文本视图（`NSTextView` 没有公开的占位符 API）。
@MainActor
final class HostEditorPlaceholderTextView: NSTextView {
  var placeholder = "" {
    didSet { needsDisplay = true }
  }

  /// 空内容时在第一行位置画灰色占位文字（多行占位按原样换行）。
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.interface(ofSize: 12.5),
      .foregroundColor: NSColor.placeholderTextColor,
    ]
    let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
    (placeholder as NSString).draw(at: origin, withAttributes: attributes)
  }

  /// 内容变空或变非空时都要重画占位文字。
  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
  }
}

/// 圆角底色里的多行输入（每行一个路径）。
@MainActor
final class HostEditorTextArea: HostsPageFilledView {
  let textView = HostEditorPlaceholderTextView()

  /// `lines` 是可见行数，决定高度。
  init(placeholder: String, identifier: String, lines: Int = 3) {
    super.init(fillColor: HostsPagePalette.control, cornerRadius: HostEditorMetrics.cornerRadius)
    translatesAutoresizingMaskIntoConstraints = false
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    textView.identifier = NSUserInterfaceItemIdentifier(identifier)
    textView.placeholder = placeholder
    textView.font = NSFont.interfaceMonospaced(ofSize: 12)
    textView.textColor = AsterTheme.ink
    textView.typingAttributes = [.font: NSFont.interfaceMonospaced(ofSize: 12), .foregroundColor: AsterTheme.ink]
    textView.insertionPointColor = AsterTheme.ink
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    // 横向内边距与单行输入框的文字起点对齐（容器 4 + 2 + 行首留白 5 ≈ 输入框 9 + 单元格 2）。
    textView.textContainerInset = NSSize(width: 2, height: 6)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    scroll.documentView = textView
    addSubview(scroll)
    scroll.pinEdges(to: self, insets: NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 2))
    let lineHeight = (textView.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 15)
    heightAnchor.constraint(equalToConstant: ceil(lineHeight * CGFloat(lines) + 14)).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  var stringValue: String {
    get { textView.string }
    set {
      textView.string = newValue
      // 直接改 `string` 用的是默认文字属性，要重新套上字体与主题色，否则值看起来像占位符。
      textView.textColor = AsterTheme.ink
      textView.font = NSFont.interfaceMonospaced(ofSize: 12)
      textView.needsDisplay = true
    }
  }
}

/// 圆角底色里的无边框下拉菜单。条目的 `representedObject` 存值。
@MainActor
final class HostEditorPopUp: HostsPageFilledView {
  let popUp = NSPopUpButton(frame: .zero, pullsDown: false)

  init(identifier: String) {
    super.init(fillColor: HostsPagePalette.control, cornerRadius: HostEditorMetrics.cornerRadius)
    translatesAutoresizingMaskIntoConstraints = false
    popUp.identifier = NSUserInterfaceItemIdentifier(identifier)
    popUp.isBordered = false
    popUp.font = NSFont.interface(ofSize: 13)
    popUp.contentTintColor = AsterTheme.ink
    popUp.autoenablesItems = false
    popUp.translatesAutoresizingMaskIntoConstraints = false
    addSubview(popUp)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: InterfaceScale.length(HostEditorMetrics.controlHeight)),
      // 无边框下拉的标题自带约 4pt 内边距，这里补到与输入框文字起点对齐。
      popUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      popUp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
      popUp.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 追加一个条目；`enabled` 为 false 时灰显不可选。
  func addItem(_ title: String, value: Any?, enabled: Bool = true, toolTip: String? = nil) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.representedObject = value
    item.isEnabled = enabled
    item.toolTip = toolTip
    popUp.menu?.addItem(item)
  }

  /// 当前选中条目的值。
  var selectedValue: Any? { popUp.selectedItem?.representedObject }

  /// 选中第一个满足条件的条目，找不到时选第一项。
  func select(where matches: (Any?) -> Bool) {
    let index = popUp.itemArray.firstIndex { matches($0.representedObject) } ?? 0
    popUp.selectItem(at: index)
  }
}

// MARK: - 按钮

/// 编辑面板底部与操作区的按钮：主按钮用强调色填充，次按钮用控件底色，危险按钮红字。
@MainActor
final class HostEditorButton: NSButton {
  enum Style {
    case primary
    case secondary
    case danger
  }

  private let style: Style
  private let handler: () -> Void
  private var tracking: NSTrackingArea?
  private var hovered = false {
    didSet { if hovered != oldValue { applyStyle() } }
  }

  /// `symbol` 非空时在文字前放图标。
  init(title: String, symbol: String? = nil, style: Style, handler: @escaping () -> Void) {
    self.style = style
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
      imagePosition = .imageLeading
      imageHugsTitle = true
    }
    font = NSFont.interface(ofSize: 12.5, weight: style == .primary ? .semibold : .medium)
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = HostEditorMetrics.cornerRadius
    layer?.cornerCurve = .continuous
    target = self
    action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: InterfaceScale.length(HostEditorMetrics.controlHeight)).isActive = true
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 文字两侧留内边距。
  override var intrinsicContentSize: NSSize {
    NSSize(width: super.intrinsicContentSize.width + 26, height: InterfaceScale.length(HostEditorMetrics.controlHeight))
  }

  override var isEnabled: Bool {
    didSet { applyStyle() }
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

  /// 按样式与悬停状态设置底色和文字色；CGColor 在当前外观上下文里解析。
  private func applyStyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let fill: NSColor
      let ink: NSColor
      switch style {
      case .primary:
        fill = hovered ? AsterTheme.accent.withAlphaComponent(0.85) : AsterTheme.accent
        ink = .white
      case .secondary:
        fill = hovered ? HostsPagePalette.controlHover : HostsPagePalette.control
        ink = AsterTheme.ink
      case .danger:
        fill = hovered ? NSColor.systemRed.withAlphaComponent(0.12) : HostsPagePalette.control
        ink = .systemRed
      }
      layer?.backgroundColor = fill.cgColor
      contentTintColor = ink
      attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: font ?? NSFont.interface(ofSize: 12.5), .foregroundColor: ink])
      alphaValue = isEnabled ? 1 : 0.45
    }
  }

  @objc private func invoke() { handler() }
}

// MARK: - 字段行与分区

/// 一行「标签 + 控件 + 可选说明」，纵向排列，宽度撑满。
@MainActor
func makeHostEditorField(_ label: String, control: NSView, hint: String? = nil) -> NSStackView {
  let title = makeLabel(label, size: 11.5, weight: .medium, color: AsterTheme.secondaryInk)
  var views: [NSView] = [title, control]
  if let hint { views.append(makeHostEditorHint(hint)) }
  let row = NSStackView(views: views)
  row.orientation = .vertical
  row.alignment = .leading
  row.spacing = 5
  row.translatesAutoresizingMaskIntoConstraints = false
  for view in views where view !== title {
    view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
  }
  return row
}

/// 字段下方的灰色说明文字，自动换行。
@MainActor
func makeHostEditorHint(_ text: String) -> NSTextField {
  let hint = makeLabel(text, size: 11, color: AsterTheme.tertiaryInk)
  hint.lineBreakMode = .byWordWrapping
  hint.maximumNumberOfLines = 0
  hint.cell?.wraps = true
  hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return hint
}

/// 两个字段并排一行；`leadingFraction` 是左侧所占宽度比例。
@MainActor
func makeHostEditorPair(_ leading: NSView, _ trailing: NSView, leadingFraction: CGFloat = 0.5) -> NSView {
  let row = NSView()
  row.translatesAutoresizingMaskIntoConstraints = false
  for view in [leading, trailing] {
    view.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(view)
  }
  let gap: CGFloat = 10
  NSLayoutConstraint.activate([
    leading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
    leading.topAnchor.constraint(equalTo: row.topAnchor),
    leading.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
    trailing.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: gap),
    trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
    trailing.topAnchor.constraint(equalTo: row.topAnchor),
    trailing.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
    leading.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: leadingFraction, constant: -gap * leadingFraction),
  ])
  // 行高跟随较高的一侧。
  let fit = row.heightAnchor.constraint(equalToConstant: 0)
  fit.priority = .defaultLow
  fit.isActive = true
  return row
}

/// 可折叠分区：可点击的标题行（箭头 + 标题）与下方的字段栈。
@MainActor
final class HostEditorSectionView: NSStackView {
  let content = NSStackView()
  private let chevron = NSImageView()
  private let header: NSButton
  private(set) var isExpanded: Bool

  /// `collapsible` 为 false 时没有箭头、始终展开。
  init(title: String, identifier: String, expanded: Bool, collapsible: Bool = true) {
    isExpanded = expanded || !collapsible
    header = NSButton(title: "", target: nil, action: nil)
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier(identifier)
    orientation = .vertical
    alignment = .leading
    spacing = 12
    translatesAutoresizingMaskIntoConstraints = false

    header.isBordered = false
    header.identifier = NSUserInterfaceItemIdentifier("\(identifier)-header")
    header.target = self
    header.action = #selector(toggle)
    header.isEnabled = collapsible
    header.setAccessibilityLabel(title)
    header.translatesAutoresizingMaskIntoConstraints = false
    let label = makeLabel(title, size: 12.5, weight: .semibold, color: AsterTheme.ink)
    label.translatesAutoresizingMaskIntoConstraints = false
    chevron.contentTintColor = AsterTheme.tertiaryInk
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.isHidden = !collapsible
    header.addSubview(chevron)
    header.addSubview(label)
    NSLayoutConstraint.activate([
      header.heightAnchor.constraint(equalToConstant: InterfaceScale.length(22)),
      chevron.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 12),
      label.leadingAnchor.constraint(equalTo: collapsible ? chevron.trailingAnchor : header.leadingAnchor, constant: collapsible ? 6 : 0),
      label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
    ])

    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    addArrangedSubview(header)
    addArrangedSubview(content)
    header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    applyExpansion()
  }

  required init?(coder: NSCoder) { nil }

  /// 追加一行字段，宽度撑满分区。
  func addRow(_ view: NSView) {
    content.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
  }

  /// 展开或收起。
  func setExpanded(_ expanded: Bool) {
    isExpanded = expanded
    applyExpansion()
  }

  @objc private func toggle() { setExpanded(!isExpanded) }

  /// 同步箭头方向与内容可见性。
  private func applyExpansion() {
    chevron.image = NSImage(
      systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(10), weight: .semibold))
    content.isHidden = !isExpanded
  }
}

extension NSLayoutConstraint {
  /// 设置优先级并返回自身，便于写在约束数组里。
  func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}
