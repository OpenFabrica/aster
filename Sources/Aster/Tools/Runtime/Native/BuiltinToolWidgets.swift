// 内置原生工具共用的小部件：根视图、卡片、结果行与结果列表、单行输入框、多行文本区、分段控件与按钮。
import AppKit
import AsterCore

// MARK: - 根视图与布局

/// 原生工具的根视图：子视图竖排撑满宽度；外观变化时回调，让依赖终端主题的子视图（JSON 树）跟着刷新。
@MainActor
final class BuiltinToolRootView: NSView {
  /// 明暗外观变化后调用。
  var onAppearanceChange: (() -> Void)?
  let stack = NSStackView()

  init() {
    super.init(frame: .zero)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.distribution = .fill
    stack.spacing = 8
    addSubview(stack)
    stack.pinEdges(to: self, insets: NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14))
  }

  /// 放入内容：`arranged` 自上而下排列；`expanding` 是吃掉剩余高度的那一块（结果区），其余保持自身高度。
  /// 与 init 分开，是因为工具条按钮的闭包要捕获内容对象，只能在它的存储属性全部就位之后再建。
  func install(arranged: [NSView], expanding: NSView?) {
    for view in arranged {
      stack.addArrangedSubview(view)
      // 宽度显式等于栈宽：栈视图的对齐只给出「前缘 = 0、后缘 ≥ 0」这类弱约束，没有固有宽度的
      // 容器（结果区）会因此宽度不定，被求解成右侧的一条窄列。隐藏的子视图仍留在栈里，约束不会丢。
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      // 固定块抗拉伸，结果区优先被拉伸；否则 `.fill` 会把多余高度分给工具条或提示行。
      let priority: NSLayoutConstraint.Priority = view === expanding ? .init(1) : .defaultHigh
      view.setContentHuggingPriority(priority, for: .vertical)
      // 嵌套的栈视图没有固有尺寸，贴合内容靠它自己的 hugging（默认 250）；不调高会被一起拉伸。
      (view as? NSStackView)?.setHuggingPriority(priority, for: .vertical)
    }
    expanding?.setContentCompressionResistancePriority(.init(1), for: .vertical)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }
}

/// 原生工具的布局工厂：工具条、按钮、提示行与固定高度，保持各工具外观一致。
@MainActor
enum BuiltinToolLayout {
  /// 工具条：左侧控件靠左、右侧按钮靠右，固定 26 点高。
  /// 用栈视图的左右两个停靠区而不是中间塞一个空白视图：空白视图没有固有宽度，两侧控件的位置会求解不定。
  static func toolbar(leading: [NSView], trailing: [NSView]) -> NSStackView {
    let bar = NSStackView()
    bar.orientation = .horizontal
    bar.alignment = .centerY
    bar.spacing = 8
    bar.setViews(leading, in: .leading)
    bar.setViews(trailing, in: .trailing)
    bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
    return bar
  }

  /// 小号圆角按钮；闭包按钮由 `ActionButton` 在自身生命周期内持有。
  static func button(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) -> ActionButton {
    let button = ActionButton(title: title, symbol: symbol, bezelStyle: .rounded, handler: handler)
    button.controlSize = .small
    button.font = NSFont.interface(ofSize: 11)
    return button
  }

  /// 提示行：次要色、可换行；`isError` 时用警示色。
  static func hintLabel() -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: "")
    label.font = NSFont.interface(ofSize: 11)
    label.textColor = AsterTheme.secondaryInk
    label.isHidden = true
    return label
  }

  /// 更新提示行：空文本隐藏。
  static func setHint(_ label: NSTextField, _ text: String?, isError: Bool = false) {
    label.stringValue = text ?? ""
    label.textColor = isError ? AsterTheme.warning : AsterTheme.secondaryInk
    label.isHidden = (text ?? "").isEmpty
  }

  /// 给块设固定高度（输入区等）；结果区不要调用。
  static func fixHeight(_ view: NSView, _ height: CGFloat) {
    view.translatesAutoresizingMaskIntoConstraints = false
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
  }
}

// MARK: - 卡片

/// 圆角卡片底：淡淡的正文色底 + 细边。颜色在 `updateLayer` 里按当前外观解析，明暗切换后自动重算。
@MainActor
final class BuiltinToolCard: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
  }

  /// 把 `content` 放进卡片并按内边距撑满。
  convenience init(content: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)) {
    self.init(frame: .zero)
    addSubview(content)
    content.pinEdges(to: self, insets: insets)
  }

  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// 动态色要在当前外观下解析成 CGColor；直接缓存 cgColor 会停在创建时的明暗。
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.04).cgColor
      layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.8).cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

// MARK: - 结果行

/// 结果里的一行：左侧标签、中间等宽可选中的值（超长按字符换行）、右侧复制按钮。
@MainActor
final class BuiltinResultRowView: NSView {
  private let labelField = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
  private let valueField = NSTextField(wrappingLabelWithString: "")
  private let onCopy: (String) -> Void
  private(set) var value = ""

  init(label: String, value: String, labelWidth: CGFloat, onCopy: @escaping (String) -> Void) {
    self.onCopy = onCopy
    super.init(frame: .zero)
    valueField.font = NSFont.interfaceMonospaced(ofSize: 12)
    valueField.textColor = AsterTheme.ink
    valueField.isSelectable = true
    valueField.lineBreakMode = .byCharWrapping
    valueField.maximumNumberOfLines = 4
    valueField.cell?.truncatesLastVisibleLine = true
    valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    labelField.lineBreakMode = .byTruncatingTail
    let copyButton = IconHoverButton(symbol: "doc.on.doc", accessibilityDescription: L("复制")) { [weak self] in
      guard let self, !self.value.isEmpty else { return }
      self.onCopy(self.value)
    }
    copyButton.toolTip = L("复制")
    for view in [labelField, valueField, copyButton] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      labelField.widthAnchor.constraint(equalToConstant: labelWidth),
      labelField.firstBaselineAnchor.constraint(equalTo: valueField.firstBaselineAnchor),
      valueField.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 8),
      valueField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      valueField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      copyButton.leadingAnchor.constraint(greaterThanOrEqualTo: valueField.trailingAnchor, constant: 6),
      copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      copyButton.centerYAnchor.constraint(equalTo: labelField.centerYAnchor),
      copyButton.widthAnchor.constraint(equalToConstant: 22),
      copyButton.heightAnchor.constraint(equalToConstant: 22),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
    ])
    update(label: label, value: value)
  }

  required init?(coder: NSCoder) { nil }

  /// 换一组标签与值（复用行，避免每次刷新都重建视图）。
  func update(label: String, value: String) {
    self.value = value
    labelField.stringValue = label
    valueField.stringValue = value
    valueField.toolTip = value.count > 64 ? value : nil
  }

  /// 多行标签需要知道自己的实际宽度才能算出换行后的高度；宽度变化时刷新首选宽度。
  override func layout() {
    super.layout()
    let width = valueField.frame.width
    if width > 0, abs(valueField.preferredMaxLayoutWidth - width) > 0.5 {
      valueField.preferredMaxLayoutWidth = width
      valueField.invalidateIntrinsicContentSize()
    }
  }
}

/// 一组结果行，竖排；`setLines` 时复用已有行，多删少补。
@MainActor
final class BuiltinResultListView: NSStackView {
  private let labelWidth: CGFloat
  private let onCopy: (String) -> Void
  private var rows: [BuiltinResultRowView] = []

  init(labelWidth: CGFloat = 72, onCopy: @escaping (String) -> Void) {
    self.labelWidth = labelWidth
    self.onCopy = onCopy
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 0
  }

  required init?(coder: NSCoder) { nil }

  /// 换成新的一组行。
  func setLines(_ lines: [ToolResultLine]) {
    while rows.count > lines.count {
      let row = rows.removeLast()
      removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    for (index, line) in lines.enumerated() {
      if index < rows.count {
        rows[index].update(label: line.label, value: line.value)
      } else {
        let row = BuiltinResultRowView(label: line.label, value: line.value, labelWidth: labelWidth, onCopy: onCopy)
        rows.append(row)
        addArrangedSubview(row)
        // 与根视图同理：行宽显式等于列表宽，不依赖栈视图对齐的弱约束。
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
      }
      rows[index].setAccessibilityLabel(line.label)
    }
  }
}

/// 可滚动的结果列表：行多（URL 参数、UUID）时在卡片里滚动，内容顶端对齐。
@MainActor
final class BuiltinScrollingResultList: NSView {
  let list: BuiltinResultListView
  private let scrollView = NSScrollView()

  init(labelWidth: CGFloat = 72, onCopy: @escaping (String) -> Void) {
    list = BuiltinResultListView(labelWidth: labelWidth, onCopy: onCopy)
    super.init(frame: .zero)
    let document = FlippedDocumentView()
    document.addSubview(list)
    list.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = document
    addSubview(scrollView)
    scrollView.pinEdges(to: self)
    let clip = scrollView.contentView
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      list.topAnchor.constraint(equalTo: document.topAnchor),
      list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 换一组行并滚回顶部。
  func setLines(_ lines: [ToolResultLine]) {
    list.setLines(lines)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}

// MARK: - 输入控件

/// 单行输入框：等宽字体，每次编辑回调一次。
@MainActor
final class BuiltinInputField: NSTextField, NSTextFieldDelegate {
  /// 用户编辑后调用（程序赋值不回调）。
  var onChange: ((String) -> Void)?

  init(placeholder: String) {
    super.init(frame: .zero)
    placeholderString = placeholder
    font = NSFont.interfaceMonospaced(ofSize: 12)
    // 系统圆角输入框自己画 textBackgroundColor 底，文字用系统 labelColor 才能保证两种外观下都看得清。
    textColor = .labelColor
    isEditable = true
    isSelectable = true
    isBezeled = true
    bezelStyle = .roundedBezel
    usesSingleLineMode = true
    cell?.isScrollable = true
    cell?.wraps = false
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  func controlTextDidChange(_ obj: Notification) {
    onChange?(stringValue)
  }
}

/// 多行文本区（输入或只读输出）：卡片底 + 等宽字体 + 占位提示。
@MainActor
final class BuiltinTextArea: NSView, NSTextViewDelegate {
  let textView = NSTextView()
  private let scrollView = NSScrollView()
  private let placeholderLabel = BuiltinPassthroughLabel(labelWithString: "")
  /// 用户编辑后调用（程序赋值不回调）。
  var onChange: ((String) -> Void)?

  init(placeholder: String, editable: Bool, font: NSFont = NSFont.interfaceMonospaced(ofSize: 12)) {
    super.init(frame: .zero)
    placeholderLabel.stringValue = placeholder
    placeholderLabel.font = NSFont.interface(ofSize: 12)
    placeholderLabel.textColor = AsterTheme.tertiaryInk
    placeholderLabel.lineBreakMode = .byTruncatingTail
    textView.font = font
    textView.textColor = AsterTheme.ink
    textView.typingAttributes = [.font: font, .foregroundColor: AsterTheme.ink]
    textView.insertionPointColor = AsterTheme.ink
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isEditable = editable
    textView.isSelectable = true
    textView.allowsUndo = editable
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = self
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = textView
    let card = BuiltinToolCard(content: scrollView, insets: NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2))
    addSubview(card)
    card.pinEdges(to: self)
    addSubview(placeholderLabel)
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 文本内容。赋值不触发 `onChange`，并重新套上字体与颜色（直接改 `string` 会丢失文字属性）。
  var string: String {
    get { textView.string }
    set {
      guard newValue != textView.string else { return }
      textView.string = newValue
      textView.font = textView.typingAttributes[.font] as? NSFont ?? NSFont.interfaceMonospaced(ofSize: 12)
      textView.textColor = AsterTheme.ink
      updatePlaceholder()
    }
  }

  /// 换显示字体（JSON 输出跟随终端字体）。
  func setFont(_ font: NSFont) {
    textView.font = font
    textView.typingAttributes[.font] = font
  }

  func textDidChange(_ notification: Notification) {
    updatePlaceholder()
    onChange?(textView.string)
  }

  /// 文本视图是滚动区的文档视图，宽度靠 autoresizing 跟随时只加减差值：首次布局前滚动区若已有过别的宽度，
  /// 文本视图会停在一条窄列里逐字折行。每次布局都把宽度对齐到可见宽度，高度仍由文本视图按内容自己增长。
  override func layout() {
    super.layout()
    let width = scrollView.contentSize.width
    guard width > 0, abs(textView.frame.width - width) > 0.5 else { return }
    textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, scrollView.contentSize.height)))
  }

  private func updatePlaceholder() {
    placeholderLabel.isHidden = !textView.string.isEmpty
  }
}

/// 不参与命中测试的标签：盖在文本区上的占位提示不能吃掉点击，否则点占位文字聚焦不到文本区。
@MainActor
final class BuiltinPassthroughLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 分段控件：选择变化时回调选中下标。
@MainActor
final class BuiltinSegmentedControl: NSSegmentedControl {
  /// 用户切换分段后调用（程序设置 `selectedSegment` 不回调）。
  var onChange: ((Int) -> Void)?

  init(labels: [String]) {
    super.init(frame: .zero)
    segmentCount = labels.count
    for (index, label) in labels.enumerated() {
      setLabel(label, forSegment: index)
    }
    trackingMode = .selectOne
    controlSize = .small
    font = NSFont.interface(ofSize: 11)
    target = self
    action = #selector(segmentChanged)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func segmentChanged() {
    onChange?(selectedSegment)
  }
}

/// 下拉菜单：选择变化时回调选中下标。
@MainActor
final class BuiltinPopUpButton: NSPopUpButton {
  /// 用户选择后调用。
  var onChange: ((Int) -> Void)?

  init(titles: [String]) {
    super.init(frame: .zero, pullsDown: false)
    addItems(withTitles: titles)
    controlSize = .small
    font = NSFont.interface(ofSize: 11)
    target = self
    action = #selector(selectionChanged)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func selectionChanged() {
    onChange?(indexOfSelectedItem)
  }
}
