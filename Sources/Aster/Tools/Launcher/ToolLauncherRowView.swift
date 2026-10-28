// 工具面板的结果行：左侧 28pt 图标块、标题 / 副标题两行、右侧徽章或 ⌘ 键帽。
// 与 Open Quickly 的通用行分开：工具面板更宽、只列工具，图标块与徽章规则按工具来定。
import AppKit
import AsterCore

/// 工具面板单行结果。只在主线程使用。
@MainActor
final class ToolLauncherRowView: NSButton {
  /// 行高（未缩放）。结果区按它算高度。
  static let baseHeight: CGFloat = 48

  var isRowSelected = false {
    didSet { needsDisplay = true }
  }
  /// 右键时弹出操作菜单；nil 时按系统默认处理。
  var onContextMenu: (() -> Void)?

  private let tile = ToolIconTileView()
  private let titleLabel = makeLabel("", size: 14, weight: .medium, color: AsterTheme.ink)
  private let detailLabel = makeLabel("", size: 12, color: AsterTheme.secondaryInk)
  private let badge = ToolLauncherCapsuleView(style: .badge)
  private let keycap = ToolLauncherCapsuleView(style: .keycap)
  private var handler: (() -> Void)?
  private var resultsWidthConstraint: NSLayoutConstraint?

  /// 结构与约束只建一次；`configure` 只换内容，行可以在结果刷新间复用。
  init() {
    super.init(frame: .zero)
    title = ""
    isBordered = false
    wantsLayer = true
    target = self
    action = #selector(invoke)

    titleLabel.lineBreakMode = .byTruncatingTail
    detailLabel.lineBreakMode = .byTruncatingMiddle
    let textColumn = NSStackView(views: [titleLabel, detailLabel])
    textColumn.orientation = .vertical
    textColumn.spacing = 2
    textColumn.alignment = .leading
    textColumn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    keycap.isHidden = true
    for view in [badge, keycap] { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
    let row = NSStackView(views: [tile, textColumn, spacer, badge, keycap])
    row.orientation = .horizontal
    row.spacing = 12
    row.alignment = .centerY
    row.setCustomSpacing(8, after: badge)
    addSubview(row)
    row.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12))
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: InterfaceScale.length(Self.baseHeight)).isActive = true
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// 选中底色在 updateLayer 里按当前外观解析，主题或明暗切换后自动跟上。
  override func updateLayer() {
    layer?.cornerRadius = 10
    layer?.backgroundColor =
      isRowSelected ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
  }

  /// 行宽跟结果栈走。跨视图约束只在行已加入栈后激活，复用前先停用。
  func attach(to stack: NSStackView) {
    resultsWidthConstraint?.isActive = false
    let constraint = widthAnchor.constraint(equalTo: stack.widthAnchor)
    constraint.isActive = true
    resultsWidthConstraint = constraint
  }

  /// 移出结果栈前停用跨视图约束。
  func detachFromResultsStack() {
    resultsWidthConstraint?.isActive = false
    resultsWidthConstraint = nil
  }

  /// 换上一行的内容。徽章只在有信息量时出现：「识别到」用强调色；内置工具不挂徽章，其它来源写运行方式。
  func configure(row: ToolLauncherRow, handler: @escaping () -> Void) {
    self.handler = handler
    onContextMenu = nil
    identifier = NSUserInterfaceItemIdentifier("tool-launcher-row-\(row.id)")
    tile.configure(entry: row.entry, symbol: row.symbol)
    titleLabel.stringValue = row.title
    detailLabel.stringValue = row.detail
    detailLabel.isHidden = row.detail.isEmpty
    let showsBadge = row.origin == .recognized || row.entry.source != .builtin
    badge.text = showsBadge ? row.badge : ""
    badge.isAccented = row.origin == .recognized
    // 按住 ⌘ 时键帽占着这个位置，徽章先不出来。
    badge.isHidden = !showsBadge || !keycap.isHidden
    toolTip = row.detail.isEmpty ? row.title : "\(row.title)\n\(row.detail)"
    setAccessibilityLabel(row.title)
  }

  /// 右侧正显示的徽章文字；没有显示时为 nil。
  var visibleBadge: String? { badge.isHidden ? nil : badge.text }
  /// 右侧正显示的键帽文字；没有显示时为 nil。
  var visibleKeycap: String? { keycap.isHidden ? nil : keycap.text }

  /// 按住 ⌘ 时在右侧显示快选键帽，暂时盖住徽章；图标与文字位置不动。
  func setCommandHint(_ hint: String?, visible: Bool) {
    let showsHint = visible && hint != nil
    keycap.text = hint ?? ""
    keycap.isHidden = !showsHint
    badge.isHidden = showsHint || badge.text.isEmpty
  }

  @objc private func invoke() { handler?() }

  /// 有菜单回调时右键弹自己的操作菜单。
  override func rightMouseDown(with event: NSEvent) {
    guard let onContextMenu else {
      super.rightMouseDown(with: event)
      return
    }
    onContextMenu()
  }
}

/// 28pt 圆角图标块：插件自带图标优先；没有时用固定深色底 + 按工具着色的符号，与内置网页工具的图标同族。
@MainActor
final class ToolIconTileView: NSView {
  static let side: CGFloat = 28
  /// 深色底。与内置网页工具 icon.svg 的底色一致，明暗外观下都不变，像一组应用图标。
  private static let tileColor = NSColor(srgbRed: 0x23 / 255, green: 0x28 / 255, blue: 0x35 / 255, alpha: 1)
  /// 插件图标按路径缓存，结果刷新时不重复读盘解码。
  private static var imageCache: [String: NSImage] = [:]

  private let imageView = NSImageView()
  private var drawsTile = true

  /// 固定尺寸，图片居中。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    let side = InterfaceScale.length(Self.side)
    widthAnchor.constraint(equalToConstant: side).isActive = true
    heightAnchor.constraint(equalToConstant: side).isActive = true
    imageView.imageScaling = .scaleProportionallyUpOrDown
    addSubview(imageView)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    imageWidth = imageView.widthAnchor.constraint(equalToConstant: side)
    imageHeight = imageView.heightAnchor.constraint(equalToConstant: side)
    imageWidth?.isActive = true
    imageHeight?.isActive = true
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  private var imageWidth: NSLayoutConstraint?
  private var imageHeight: NSLayoutConstraint?

  /// 图片显示边长：插件图标铺满整块，符号留出边距。
  private func setImageSize(_ size: CGFloat) {
    imageWidth?.constant = size
    imageHeight?.constant = size
  }

  override var wantsUpdateLayer: Bool { true }

  /// 只有画符号时才铺深色底，并加一圈极淡的亮边，深色面板上图标块的边界才不发软；插件图标自带底色与圆角。
  override func updateLayer() {
    layer?.cornerRadius = InterfaceScale.length(7)
    layer?.masksToBounds = true
    layer?.backgroundColor = drawsTile ? Self.tileColor.cgColor : NSColor.clear.cgColor
    layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    layer?.borderWidth = drawsTile ? 1 : 0
  }

  /// 按条目选图：能读出插件图标就用它，否则画符号。
  func configure(entry: ToolCatalogEntry, symbol: String) {
    let side = InterfaceScale.length(Self.side)
    if let path = entry.iconPath, let image = Self.image(at: path) {
      drawsTile = false
      imageView.image = image
      imageView.contentTintColor = nil
      setImageSize(side)
    } else {
      drawsTile = true
      imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      imageView.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: InterfaceScale.length(14), weight: .semibold)
      imageView.contentTintColor = Self.tint(for: entry)
      setImageSize(side - InterfaceScale.length(10))
    }
    needsDisplay = true
  }

  /// 读取并缓存插件图标；读不出来返回 nil，由调用方退回符号。
  private static func image(at path: String) -> NSImage? {
    if let cached = imageCache[path] { return cached }
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    imageCache[path] = image
    return image
  }

  /// 符号颜色：内置原生工具每个一种色相，便于扫读；其它工具用中性浅灰。深色底上都要清楚。
  private static func tint(for entry: ToolCatalogEntry) -> NSColor {
    guard entry.pluginID == BuiltinToolCatalog.pluginID,
      let handler = ToolBuiltinHandler(rawValue: entry.feature.code)
    else { return NSColor(white: 0.82, alpha: 1) }
    let hex: UInt32
    switch handler {
    case .timestamp: hex = 0xFF9F0A
    case .base64: hex = 0x64D2FF
    case .url: hex = 0x0A84FF
    case .hash: hex = 0xBF5AF2
    case .uuid: hex = 0x30D158
    case .ports: hex = 0xFF6961
    case .json: hex = 0xFFD60A
    }
    return NSColor(
      srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

/// 行右侧的小胶囊：徽章（「识别到」等）或 ⌘ 键帽。颜色在 updateLayer 里按外观解析。
@MainActor
final class ToolLauncherCapsuleView: NSView {
  enum Style { case badge, keycap }

  private let style: Style
  private let label: NSTextField

  var text: String {
    get { label.stringValue }
    set { label.stringValue = newValue }
  }
  /// 徽章用强调色（「识别到」）：强调色底、主文字色，压在同样是强调色调的选中行上也读得清。
  var isAccented = false {
    didSet {
      label.textColor = isAccented ? AsterTheme.ink : AsterTheme.secondaryInk
      needsDisplay = true
    }
  }

  /// 按样式定字号。
  init(style: Style) {
    self.style = style
    // 键帽是要按的键，用主文字色；徽章是附注，用次色。
    label = makeLabel(
      "", size: style == .keycap ? 11 : 10, weight: .medium,
      color: style == .keycap ? AsterTheme.ink : AsterTheme.secondaryInk)
    super.init(frame: .zero)
    wantsLayer = true
    addSubview(label)
    label.pinEdges(to: self, insets: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// 徽章是淡色底；键帽是带细边的面板色底，像一枚按键。
  override func updateLayer() {
    layer?.cornerRadius = 5
    switch style {
    case .badge:
      let base = isAccented ? AsterTheme.accent : AsterTheme.secondaryInk
      layer?.backgroundColor = base.withAlphaComponent(isAccented ? 0.30 : 0.12).cgColor
      layer?.borderWidth = 0
    case .keycap:
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.08).cgColor
      layer?.borderColor = AsterTheme.ink.withAlphaComponent(0.15).cgColor
      layer?.borderWidth = 1
    }
  }
}
