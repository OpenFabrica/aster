import AppKit
import AsterCore

/// 与 Otty 文件工具条一致的紧凑布局；文件名由外层 Pane 标题承载。
@MainActor
final class FilePaneToolbar: NSView {
  let zoom = NSPopUpButton(frame: .zero, pullsDown: false)
  let status = NSTextField(labelWithString: "")
  let spinner = NSProgressIndicator()
  let openButton: NSButton
  let runButton: NSButton
  let resumeButton: NSButton
  /// JSON 源码模式的“格式化”；显隐由文件 Pane 按分类与可编辑状态决定。
  let formatButton: NSButton
  private let saveButton: NSButton
  private let discardButton: NSButton
  private let closeButton: NSButton
  private let savedButton: NSButton
  private let zoomDivider = NSBox()
  private var compact = false
  private let captions: [(NSButton, String)]
  private let captionWidths: [NSLayoutConstraint]
  var onZoom: ((Double) -> Void)?
  var onZoomToFit: (() -> Void)?

  init(mode: NSSegmentedControl, send: @escaping () -> Void, open: @escaping () -> Void,
    save: @escaping () -> Void, discard: @escaping () -> Void, run: @escaping () -> Void,
    resume: (() -> Void)? = nil, format: (() -> Void)? = nil, close: @escaping () -> Void) {
    func action(_ title: String, symbol: String, id: String, handler: @escaping () -> Void) -> NSButton {
      let button = ActionButton(title: title, bezelStyle: .inline, handler: handler)
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
      button.imagePosition = .imageLeading
      button.isBordered = false
      button.font = NSFont.interface(ofSize: 11)
      button.contentTintColor = AsterTheme.secondaryInk
      button.attributedTitle = NSAttributedString(string: title,
        attributes: [.font: NSFont.interface(ofSize: 11), .foregroundColor: AsterTheme.secondaryInk])
      button.identifier = .init(id)
      button.toolTip = title
      button.setAccessibilityLabel(title)
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.heightAnchor.constraint(equalToConstant: 22).isActive = true
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
      return button
    }
    saveButton = action(L("保存"), symbol: "checkmark", id: "file-pane-save", handler: save)
    discardButton = action(L("放弃更改"), symbol: "xmark", id: "file-pane-discard", handler: discard)
    closeButton = action(L("关闭文件"), symbol: "xmark", id: "file-pane-close", handler: close)
    savedButton = action(L("已保存"), symbol: "checkmark", id: "file-pane-saved") {}
    savedButton.isEnabled = false
    resumeButton = action("Resume", symbol: "play.circle", id: "file-pane-resume") { resume?() }
    resumeButton.isHidden = resume == nil
    formatButton = action(L("格式化"), symbol: "curlybraces", id: "file-pane-format") { format?() }
    formatButton.isHidden = true
    let chat = IconHoverButton(symbol: "bubble.left", accessibilityDescription: "Send to Chat", handler: send)
    chat.identifier = .init("file-pane-send-to-chat")
    chat.toolTip = L("发送到 Chat") + "…"
    let openButton = IconHoverButton(symbol: "square.and.arrow.up", accessibilityDescription: L("打开方式"), handler: open)
    openButton.identifier = .init("file-pane-open-in")
    openButton.toolTip = L("打开方式")
    self.openButton = openButton
    let runButton = IconHoverButton(symbol: "play.fill", accessibilityDescription: L("运行脚本"), handler: run)
    runButton.identifier = .init("file-pane-run")
    runButton.toolTip = L("运行脚本")
    self.runButton = runButton
    let captions = [(formatButton, L("格式化")), (saveButton, L("保存")), (discardButton, L("放弃更改")),
      (savedButton, L("已保存")), (resumeButton, "Resume"), (closeButton, L("关闭文件"))]
    self.captions = captions
    captionWidths = captions.map { button, _ in
      button.widthAnchor.constraint(equalToConstant: ceil(button.attributedTitle.size().width) + 24)
    }
    super.init(frame: .zero)
    identifier = .init("file-pane-toolbar")
    wantsLayer = true
    NSLayoutConstraint.activate(captionWidths)
    heightAnchor.constraint(equalToConstant: 32).isActive = true
    mode.segmentStyle = .texturedRounded
    mode.controlSize = .small
    for segment in 0..<mode.segmentCount { mode.setWidth(23, forSegment: segment) }
    mode.widthAnchor.constraint(equalToConstant: 46).isActive = true
    mode.heightAnchor.constraint(equalToConstant: 22).isActive = true
    zoom.identifier = .init("file-pane-zoom")
    zoom.isBordered = false
    zoom.font = NSFont.interface(ofSize: 11)
    zoom.setAccessibilityLabel(L("缩放"))
    zoom.target = self
    zoom.action = #selector(changeZoom)
    for percent in [25, 50, 75, 100, 150, 200, 400] {
      zoom.addItem(withTitle: "\(percent)%")
      zoom.lastItem?.tag = percent
    }
    zoom.selectItem(withTag: 100)
    zoom.menu?.addItem(.separator())
    for (title, tag, key) in [(L("放大"), -1, "+"), (L("缩小"), -2, "-"),
      (L("实际大小"), -3, "0"), (L("缩放以适应"), -4, "")] {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
      item.tag = tag
      zoom.menu?.addItem(item)
    }
    zoom.widthAnchor.constraint(equalToConstant: 60).isActive = true
    let divider = zoomDivider
    divider.boxType = .separator
    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    divider.heightAnchor.constraint(equalToConstant: 14).isActive = true
    let leading = NSStackView(views: [mode, zoom, divider, chat, runButton, openButton])
    leading.orientation = .horizontal
    leading.alignment = .centerY
    leading.spacing = 5
    for button in [chat, runButton, openButton] {
      button.widthAnchor.constraint(equalToConstant: 24).isActive = true
      button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    status.identifier = .init("file-pane-status")
    status.font = NSFont.interface(ofSize: 10.5)
    status.textColor = AsterTheme.warning
    status.lineBreakMode = .byTruncatingTail
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    let trailing = NSStackView(views: [spinner, status, formatButton, saveButton, discardButton, savedButton, resumeButton, closeButton])
    trailing.orientation = .horizontal
    trailing.alignment = .centerY
    trailing.spacing = 5
    let row = NSStackView(views: [leading, NSView(), trailing])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
    addSubview(row)
    row.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }

  func update(editable: Bool, dirty: Bool, statusText: String?) {
    saveButton.isHidden = !editable || !dirty
    discardButton.isHidden = !editable || !dirty
    savedButton.isHidden = !editable || dirty
    closeButton.isHidden = dirty
    status.stringValue = statusText ?? ""
    status.toolTip = statusText
    status.isHidden = statusText == nil
  }

  func showZoom(_ visible: Bool) {
    zoom.isHidden = !visible
    zoomDivider.isHidden = !visible
  }

  override func layout() {
    let nextCompact = bounds.width < 280
    if nextCompact != compact {
      compact = nextCompact
      for (index, entry) in captions.enumerated() {
        let (button, caption) = entry
        button.attributedTitle = NSAttributedString(string: compact ? "" : caption,
          attributes: [.font: NSFont.interface(ofSize: 11), .foregroundColor: AsterTheme.secondaryInk])
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.bezelStyle = compact ? .accessoryBarAction : .inline
        captionWidths[index].constant = compact ? 22 : ceil(button.attributedTitle.size().width) + 24
      }
    }
    super.layout()
  }

  @objc private func changeZoom() {
    let tag = zoom.selectedTag()
    switch tag {
    case -4: onZoomToFit?(); return
    case -3: selectZoom(1)
    case -2: selectZoom(max(0.1, zoomFactor / 1.25))
    case -1: selectZoom(min(16, zoomFactor * 1.25))
    default: selectZoom(Double(tag) / 100)
    }
  }

  private var zoomFactor: Double = 1

  func selectZoom(_ factor: Double) {
    zoomFactor = factor
    let percent = Int((factor * 100).rounded())
    if zoom.menu?.item(withTag: percent) == nil {
      zoom.insertItem(withTitle: "\(percent)%", at: 0)
      zoom.item(at: 0)?.tag = percent
    }
    zoom.selectItem(withTag: percent)
    onZoom?(factor)
  }
}
