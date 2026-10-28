// 工具面板的外框视图：圆角根视图（接收拖入的文件）、搜索行与搜索框的 field editor、
// 一像素分隔线，以及底部的按键提示 / 短提示栏。
import AppKit
import AsterCore

/// 面板根视图：圆角背景随外观重绘，并接收拖进来的文件。
@MainActor
final class ToolLauncherRootView: NSView {
  /// 拖入的文件（绝对路径）。
  var onDropFiles: (([String]) -> Void)?

  /// 开启图层并注册文件拖放。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    registerForDraggedTypes([.fileURL])
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// 动态颜色在 updateLayer 里按当前外观解析；外观切换时 AppKit 会再调一次。
  override func updateLayer() {
    layer?.backgroundColor = AsterTheme.panel.cgColor
    layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.9).cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = 14
    layer?.masksToBounds = true
  }

  /// 只接受文件 URL。
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    Self.fileURLs(from: sender).isEmpty ? [] : .copy
  }

  /// 把拖入的文件路径交给内容控制器。
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let paths = Self.fileURLs(from: sender).map(\.path)
    guard !paths.isEmpty else { return false }
    onDropFiles?(paths)
    return true
  }

  /// 读取拖拽板里的文件 URL（忽略普通网址）。搜索框的 field editor 也用它。
  fileprivate static func fileURLs(from info: any NSDraggingInfo) -> [URL] {
    info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
}

/// 搜索行：放大镜、已打开工具的名字、大号搜索框、拖入文件的标记（点它清掉文件），以及钉住按钮。
/// 搜索框的 delegate、文件标记与钉住按钮的动作由内容控制器接上。
@MainActor
final class ToolLauncherSearchBar: NSStackView {
  let searchField = NSTextField()
  let toolChip = makeLabel("", size: 12, weight: .semibold, color: AsterTheme.accent)
  let filesButton = NSButton()
  let pinButton = NSButton()

  /// 钉住按钮的外观：钉住时实心图钉、强调色。
  var isPinned = false {
    didSet { updatePinButton() }
  }

  /// 按固定行高搭建搜索行。
  init(height: CGFloat) {
    super.init(frame: .zero)
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("搜索"))
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    icon.contentTintColor = AsterTheme.secondaryInk
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
    searchField.font = NSFont.interface(ofSize: 20)
    searchField.isBezeled = false
    searchField.drawsBackground = false
    searchField.focusRingType = .none
    searchField.cell?.wraps = false
    searchField.cell?.isScrollable = true
    searchField.identifier = NSUserInterfaceItemIdentifier("tool-launcher-search")
    searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    toolChip.isHidden = true
    toolChip.setContentCompressionResistancePriority(.required, for: .horizontal)
    filesButton.bezelStyle = .inline
    filesButton.isHidden = true
    filesButton.font = NSFont.interface(ofSize: 11)
    pinButton.isBordered = false
    pinButton.imagePosition = .imageOnly
    pinButton.identifier = NSUserInterfaceItemIdentifier("tool-launcher-pin")
    pinButton.setContentHuggingPriority(.required, for: .horizontal)
    updatePinButton()
    for view in [icon, toolChip, searchField, filesButton, pinButton] { addArrangedSubview(view) }
    orientation = .horizontal
    alignment = .centerY
    spacing = 10
    // 与结果行对齐：放大镜中线对准行图标块中线（8 + 10 + 14），输入文字起点对准行标题（再 + 14 + 12）。
    edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 16)
    setCustomSpacing(16, after: icon)
    heightAnchor.constraint(equalToConstant: height).isActive = true
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 按钉住状态切换图钉图标、颜色与提示。
  private func updatePinButton() {
    let title = isPinned ? L("取消钉住") : L("钉住面板")
    pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: title)
    pinButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    pinButton.contentTintColor = isPinned ? AsterTheme.accent : AsterTheme.secondaryInk
    pinButton.toolTip = isPinned ? title : L("钉住面板：点别处时不自动收起")
    pinButton.setAccessibilityLabel(title)
  }
}

/// 搜索框专用的 field editor。默认的 field editor 会把拖进来的文件当文字，把路径插进搜索框；
/// 这里改成交给面板按文件输入（`source: .file`）处理。其它拖拽（文字等）仍按默认方式编辑。
@MainActor
final class ToolLauncherSearchFieldEditor: NSTextView {
  /// 拖到搜索框上的文件（绝对路径）。
  var onDropFiles: (([String]) -> Void)?

  /// 文件拖拽显示「拷贝」，其它拖拽照常。
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    ToolLauncherRootView.fileURLs(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
  }

  /// 同 `draggingEntered`：文件拖拽不显示文字插入点。
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    ToolLauncherRootView.fileURLs(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
  }

  /// 文件交给面板；没有文件或没有接收方时按默认方式插入文字。
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let paths = ToolLauncherRootView.fileURLs(from: sender).map(\.path)
    guard !paths.isEmpty, let onDropFiles else { return super.performDragOperation(sender) }
    onDropFiles(paths)
    return true
  }
}

/// 一像素分隔线，颜色随外观重绘。
@MainActor
final class ToolLauncherSeparatorView: NSView {
  /// 开启图层，尺寸交给 Auto Layout。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// 按当前外观解析分隔线颜色。
  override func updateLayer() {
    layer?.backgroundColor = AsterTheme.hairline.cgColor
  }
}

/// 底部栏：平时显示按键提示；有短提示时临时替换几秒，错误用红色。
@MainActor
final class ToolLauncherFooterView: NSView {
  private let hintLabel = makeLabel("", size: 11, color: AsterTheme.tertiaryInk)
  private let noticeLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
  /// 每条短提示一个代号；到点时代号已变（又来了新提示或被收起）就不再动它。
  private var noticeGeneration = 0

  /// 按键提示，按顺序排开。每条第一个空格前是按键（加粗），之后是说明；都用次色，三级色在浅色底上太淡。
  var hints: [String] = [] {
    didSet { hintLabel.attributedStringValue = Self.attributedHints(hints) }
  }

  /// 把「↩ 打开」拆成按键与说明分别着色；没有空格的整条当按键（例如 ⌘1–9）。
  private static func attributedHints(_ hints: [String]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let keyAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.interface(ofSize: 11, weight: .semibold), .foregroundColor: AsterTheme.secondaryInk,
    ]
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.interface(ofSize: 11), .foregroundColor: AsterTheme.secondaryInk,
    ]
    for (index, hint) in hints.enumerated() {
      if index > 0 { result.append(NSAttributedString(string: "     ", attributes: labelAttributes)) }
      let parts = hint.split(separator: " ", maxSplits: 1).map(String.init)
      result.append(NSAttributedString(string: parts.first ?? hint, attributes: keyAttributes))
      if parts.count == 2 { result.append(NSAttributedString(string: " " + parts[1], attributes: labelAttributes)) }
    }
    return result
  }

  /// 搭建「短提示 | 按键提示 | 弹性空白」一行。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    noticeLabel.isHidden = true
    let row = NSStackView(views: [noticeLabel, hintLabel, NSView()])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    // 左边对齐结果行的图标块（8 + 10）。
    row.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 16)
    addSubview(row)
    row.pinEdges(to: self)
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 显示一条短提示；时长随文字长短在 2.5–8 秒之间。
  func showNotice(_ text: String, isError: Bool) {
    noticeGeneration += 1
    let generation = noticeGeneration
    noticeLabel.stringValue = text
    noticeLabel.textColor = isError ? .systemRed : AsterTheme.secondaryInk
    noticeLabel.isHidden = false
    hintLabel.isHidden = true
    let duration = min(8.0, max(2.5, Double(text.count) * 0.09))
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
      guard let self, self.noticeGeneration == generation else { return }
      self.hideNotice()
    }
  }

  /// 收起短提示，恢复按键提示。
  func hideNotice() {
    noticeGeneration += 1
    noticeLabel.isHidden = true
    hintLabel.isHidden = false
  }
}
