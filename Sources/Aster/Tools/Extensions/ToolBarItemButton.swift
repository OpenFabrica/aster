// bar 上的一个可点项目：SF Symbol 或插件图标 + 11pt 文字，悬停圆角底、按下反馈。颜色在 updateLayer
// 里按当前外观解析，主题或明暗切换后不用重建。条本体与布局在 ToolBarView.swift。
import AppKit
import AsterCore

/// bar 用到的颜色。主题给了就取主题令牌，否则退回 `AsterTheme` 动态色。
struct ToolBarPalette {
  var text: NSColor
  var border: NSColor
  var accent: NSColor
  var success: NSColor
  var warning: NSColor
  var error: NSColor

  /// 悬停底色。
  var hover: NSColor { text.withAlphaComponent(0.12) }
  /// 按下底色。
  var pressed: NSColor { text.withAlphaComponent(0.2) }

  /// 按主题解析：文字 `interface.secondaryForeground`、分隔线 `interface.border`、强调 `interface.accent`；
  /// 成功 / 警告 / 错误取 ANSI 绿 / 黄 / 红，和终端里同类提示同色。
  static func resolve(theme: TerminalTheme?) -> ToolBarPalette {
    guard let theme else {
      return ToolBarPalette(
        text: AsterTheme.secondaryInk, border: AsterTheme.hairline, accent: AsterTheme.accent,
        success: .systemGreen, warning: .systemOrange, error: .systemRed)
    }
    let palette = theme.palette
    let ansi = palette.ansiColors
    func ansiColor(_ index: Int, _ fallback: NSColor) -> NSColor {
      ansi.indices.contains(index) ? NSColor(ansi[index]) : fallback
    }
    return ToolBarPalette(
      text: NSColor(theme.resolvedColor(forSlot: "interface.secondaryForeground") ?? palette.secondaryForeground),
      border: NSColor(
        theme.resolvedColor(forSlot: "interface.border") ?? palette.interfaceBorder ?? palette.secondaryForeground),
      accent: NSColor(theme.resolvedColor(forSlot: "interface.accent") ?? palette.accent),
      success: ansiColor(2, .systemGreen), warning: ansiColor(3, .systemOrange), error: ansiColor(1, .systemRed))
  }

  /// 项目颜色：十六进制原样；令牌映射到主题色。
  func color(for color: ToolBarColor?) -> NSColor {
    switch color {
    case nil, .token(.secondary)?: text
    case .rgba(let red, let green, let blue, let alpha)?:
      NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    case .token(.accent)?: accent
    case .token(.success)?: success
    case .token(.warning)?: warning
    case .token(.error)?: error
    }
  }
}

/// bar 上的一个按钮。只在主线程使用。
@MainActor
final class ToolBarItemButton: NSControl {
  /// 单项最大宽度（未缩放）；文字超出尾部截断。
  static let maximumWidth: CGFloat = 160
  /// 插件图标与图片项目按路径缓存，每次刷新不重复读盘解码；超过上限整份清空。
  private static var imageCache: [String: NSImage] = [:]
  private static let imageCacheLimit = 64

  /// 显示什么。
  enum Content: Equatable {
    case item(ToolBarItem)
    /// 运行失败：插件图标 + 警告三角，点击重跑。
    case failure(message: String, iconPath: String?)
    /// 需要授权，点击弹授权确认。
    case approval(pluginName: String)
  }

  private(set) var content: Content = .item(ToolBarItem())
  var palette = ToolBarPalette.resolve(theme: nil) {
    didSet { applyColors() }
  }
  /// 点击（鼠标松开在按钮内或辅助功能按下）。
  var onPress: (() -> Void)?

  private let iconView = NSImageView()
  /// 失败项的第二个图标（警告三角）。
  private let badgeView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false
  private var isPressed = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    label.font = .interface(ofSize: 11)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    for view in [iconView, badgeView] { view.imageScaling = .scaleProportionallyDown }
    [iconView, badgeView, label].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 换内容；同一按钮跨刷新复用，悬停态因此保留。
  func configure(_ content: Content) {
    self.content = content
    let symbolSize = InterfaceScale.font(11)
    badgeView.image = nil
    switch content {
    case .item(let item):
      iconView.image = item.symbol.flatMap { Self.symbol($0, size: symbolSize) }
        ?? item.iconFile.flatMap(Self.fileImage)
      label.stringValue = item.text ?? ""
      toolTip = ToolBarActionPerformer.tooltip(for: item)
      setAccessibilityLabel(item.text ?? item.tooltip ?? item.symbol)
    case .failure(let message, let iconPath):
      iconView.image = iconPath.flatMap(Self.fileImage) ?? Self.symbol("puzzlepiece.extension", size: symbolSize)
      badgeView.image = Self.symbol("exclamationmark.triangle", size: symbolSize)
      label.stringValue = ""
      toolTip = L("运行失败：\(message)\n点击重试")
      setAccessibilityLabel(L("运行失败：\(message)"))
    case .approval(let pluginName):
      iconView.image = Self.symbol("lock", size: symbolSize)
      label.stringValue = L("需要授权")
      toolTip = L("插件「\(pluginName)」需要授权才能运行")
      setAccessibilityLabel(toolTip)
    }
    label.isHidden = label.stringValue.isEmpty
    applyColors()
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  /// 图标与文字都没有（例如符号名在系统里不存在且没写文字）：布局时跳过。
  var hasContent: Bool { iconView.image != nil || !label.stringValue.isEmpty }

  // MARK: - 尺寸与布局

  private var horizontalPadding: CGFloat { InterfaceScale.length(5) }
  private var gap: CGFloat { InterfaceScale.length(4) }
  private var iconSide: CGFloat { InterfaceScale.length(14) }

  /// 宽度 = 内边距 + 图标 + 间距 + 文字，不超过 `maximumWidth`；高度由条决定。
  override var intrinsicContentSize: NSSize {
    var width = horizontalPadding * 2
    let icons = [iconView, badgeView].filter { $0.image != nil }
    width += CGFloat(icons.count) * iconSide + CGFloat(max(0, icons.count - 1)) * gap
    if !label.stringValue.isEmpty {
      if !icons.isEmpty { width += gap }
      width += labelWidth
    }
    return NSSize(width: min(width, InterfaceScale.length(Self.maximumWidth)), height: NSView.noIntrinsicMetric)
  }

  /// 文字需要的宽度。单行 label 的 `intrinsicContentSize` 只量字形、不含 cell 左右各 2pt 的
  /// 内边距，按它给宽度会让每一项都被截成「5h 4…」；cell 的 `cellSize` 才是画字时真正要的宽度。
  private var labelWidth: CGFloat {
    ceil(max(label.cell?.cellSize.width ?? 0, label.intrinsicContentSize.width))
  }

  override func layout() {
    super.layout()
    var x = horizontalPadding
    for view in [iconView, badgeView] {
      guard view.image != nil else {
        view.frame = .zero
        continue
      }
      view.frame = NSRect(x: x, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
      x = view.frame.maxX + gap
    }
    let labelHeight = ceil(label.intrinsicContentSize.height)
    label.frame = NSRect(
      x: x, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - x - horizontalPadding),
      height: labelHeight)
  }

  // MARK: - 颜色

  override var wantsUpdateLayer: Bool { true }

  /// 悬停 / 按下底色按当前外观解析成 CGColor。
  override func updateLayer() {
    layer?.cornerRadius = InterfaceScale.length(5)
    let color = isPressed ? palette.pressed : isHovering ? palette.hover : NSColor.clear
    var resolved = NSColor.clear.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
    layer?.backgroundColor = resolved
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// 文字与模板图标着色：项目自带颜色优先；失败项的三角用警告色；授权项用强调色。
  private func applyColors() {
    let tint: NSColor
    switch content {
    case .item(let item): tint = palette.color(for: item.color)
    case .approval: tint = palette.accent
    case .failure: tint = palette.text
    }
    label.textColor = tint
    iconView.contentTintColor = tint
    badgeView.contentTintColor = palette.warning
    needsDisplay = true
  }

  // MARK: - 鼠标

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    setHovering(true)
  }

  override func mouseExited(with event: NSEvent) {
    setHovering(false)
    setPressed(false)
  }

  /// 隐藏时收不到 `mouseExited`，重新显示会残留悬停态。
  override var isHidden: Bool {
    didSet {
      guard isHidden else { return }
      setHovering(false)
      setPressed(false)
    }
  }

  override func mouseDown(with event: NSEvent) {
    setPressed(true)
  }

  override func mouseDragged(with event: NSEvent) {
    setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
  }

  /// 松开在按钮内才算点击，与系统按钮一致。
  override func mouseUp(with event: NSEvent) {
    let inside = bounds.contains(convert(event.locationInWindow, from: nil))
    setPressed(false)
    if inside { onPress?() }
  }

  override func accessibilityPerformPress() -> Bool {
    onPress?()
    return true
  }

  /// 项目的文字标题（侧栏列表与测试用）：文字，否则 tooltip，否则符号名。
  var menuTitle: String {
    switch content {
    case .item(let item): item.text ?? item.tooltip ?? item.symbol ?? L("项目")
    case .failure(let message, _): L("运行失败：\(message)")
    case .approval: L("需要授权")
    }
  }

  private func setHovering(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    needsDisplay = true
  }

  private func setPressed(_ pressed: Bool) {
    guard isPressed != pressed else { return }
    isPressed = pressed
    needsDisplay = true
  }

  // MARK: - 图片

  /// SF Symbol；系统里没有这个名字时返回 nil（调用方丢图保字）。
  static func symbol(_ name: String, size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
  }

  /// 插件目录里的图标文件（路径已在解析阶段确认在目录内）。读不出来返回 nil。
  static func fileImage(_ path: String) -> NSImage? {
    if let cached = imageCache[path] { return cached }
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    if imageCache.count >= imageCacheLimit { imageCache.removeAll() }
    imageCache[path] = image
    return image
  }
}
