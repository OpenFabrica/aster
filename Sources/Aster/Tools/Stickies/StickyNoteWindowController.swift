// 一张便笺的窗口：彩色纸面、无标题文字的细标题栏、整块可编辑的带格式正文。功能与快捷键对齐 macOS「便笺」：
// 字体（显示字体、粗体、斜体、下划线、放大、缩小）、六种颜色、浮在最前面、半透明，双击标题栏折叠。
// 纸面固定浅色，不随 App 的深色外观变黑。改动交给 StickyNoteCenter 保存。
import AppKit
import AsterCore

/// 一张便笺的窗口控制器。只由 `StickyNoteCenter` 创建与持有。
@MainActor
final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  /// 正文默认字体与颜色（没有格式的便笺、新输入的文字）。
  private static let defaultFont = NSFont.interface(ofSize: 13)
  private static let defaultTextColor = NSColor(white: 0.12, alpha: 1)
  /// 半透明时的窗口不透明度。
  private static let translucentAlpha: CGFloat = 0.75

  let noteID: UUID
  private weak var center: StickyNoteCenter?
  /// 系统配好的滚动文本区：正文铺满可见区域，点空白处也能把光标放进去。
  private let scroll = NSTextView.scrollableTextView()
  private let textView: NSTextView
  private let paper = StickyNoteFillView()
  private let titlebarStrip = StickyNoteFillView()
  /// 折叠后显示在标题栏里的第一行文字。
  private let collapsedTitle = makeLabel("", size: 11, weight: .medium, color: NSColor(white: 0.2, alpha: 1))
  /// 标题栏高度：按窗口实际的标题栏算，色带正好盖住它，折叠后窗口就是这么高。
  private let titlebarHeight: CGFloat
  /// 折叠前的窗口高度；展开时恢复，记位置时也按它记。
  private var expandedHeight: CGFloat?
  private var isClosingWithoutSaving = false

  /// 按便笺内容搭窗口；位置在 `present` 时定。
  init(note: StickyNote, center: StickyNoteCenter) {
    noteID = note.id
    self.center = center
    textView = scroll.documentView as? NSTextView ?? NSTextView()
    let window = StickyNoteWindow(
      contentRect: NSRect(origin: .zero, size: StickyNoteCenter.defaultSize),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    window.followsAppAppearance = false
    window.appearance = NSAppearance(named: .aqua)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 160, height: 100)
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.standardWindowButton(.closeButton)?.toolTip = L("收起便笺（内容会保留）")
    let measured = window.frame.height - window.contentLayoutRect.height
    titlebarHeight = measured > 0 ? measured : 28
    super.init(window: window)
    window.delegate = self
    window.onCommand = { [weak self] command in self?.perform(command) }
    window.onToggleCollapse = { [weak self] in self?.toggleCollapsed() }
    window.contentView = makeContent()
    load(note)
    textView.delegate = self
    apply(color: note.color)
    apply(floatsOnTop: note.floatsOnTop)
    apply(translucent: note.isTranslucent)
    updateTitle()
    if let frame = note.frame, Self.isOnScreen(frame) {
      window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
    } else {
      window.center()
    }
    if note.isCollapsed { setCollapsed(true, animate: false) }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 正文滚动区占满标题栏以下；顶上一条略深的色带盖住标题栏，可以拖动窗口，折叠后在上面显示第一行。
  private func makeContent() -> NSView {
    // 纸面由视图自己画：窗口背景色在透明标题栏下的混合方式随系统版本变化，颜色不稳。
    let root = paper
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    textView.isRichText = true
    textView.importsGraphics = false
    textView.usesFontPanel = true
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.insertionPointColor = Self.defaultTextColor
    textView.textContainerInset = NSSize(width: 8, height: 6)
    textView.setAccessibilityLabel(L("便笺"))
    collapsedTitle.lineBreakMode = .byTruncatingTail
    collapsedTitle.isHidden = true
    for view in [titlebarStrip, scroll, collapsedTitle] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    NSLayoutConstraint.activate([
      titlebarStrip.topAnchor.constraint(equalTo: root.topAnchor),
      titlebarStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      titlebarStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      titlebarStrip.heightAnchor.constraint(equalToConstant: titlebarHeight),
      // 左边让开关闭按钮。
      collapsedTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
      collapsedTitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
      collapsedTitle.centerYAnchor.constraint(equalTo: titlebarStrip.centerYAnchor),
      scroll.topAnchor.constraint(equalTo: titlebarStrip.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    return root
  }

  /// 装入正文：有格式就按 RTF 还原（读不了退回纯文本），没有就用默认字体显示纯文本。
  private func load(_ note: StickyNote) {
    let defaults: [NSAttributedString.Key: Any] = [.font: Self.defaultFont, .foregroundColor: Self.defaultTextColor]
    textView.typingAttributes = defaults
    if let data = note.richText, let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
      textView.textStorage?.setAttributedString(rich)
    } else {
      textView.textStorage?.setAttributedString(NSAttributedString(string: note.text, attributes: defaults))
    }
    textView.undoManager?.removeAllActions()
  }

  // MARK: - 显示

  /// 显示窗口。`activate` 为 true 时激活 Aster 并把光标放到正文末尾，可以直接打字。
  func present(activate: Bool) {
    guard let window else { return }
    guard activate else {
      window.orderFront(nil)
      return
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
  }

  /// 换纸面颜色。
  func apply(color: StickyNoteColor) {
    window?.backgroundColor = StickyNotePalette.paper(color)
    paper.color = StickyNotePalette.paper(color)
    titlebarStrip.color = StickyNotePalette.strip(color)
  }

  /// 浮在其它窗口（包括别的应用）上面。
  func apply(floatsOnTop: Bool) {
    window?.level = floatsOnTop ? .floating : .normal
  }

  /// 半透明：能透过便笺看到后面的窗口。
  func apply(translucent: Bool) {
    window?.alphaValue = translucent ? Self.translucentAlpha : 1
  }

  /// 删除便笺时关窗口：不再回写「已隐藏」。
  func closeWithoutSaving() {
    isClosingWithoutSaving = true
    window?.close()
  }

  /// 把当前位置写回（App 退出前、移动与改大小后）。折叠时按展开的高度记，顶边不变。
  func commitPendingFrame() {
    guard let window, window.isVisible else { return }
    var frame = window.frame
    if let expandedHeight {
      frame = NSRect(x: frame.minX, y: frame.maxY - expandedHeight, width: frame.width, height: expandedHeight)
    }
    center?.noteFrameDidChange(id: noteID, frame: frame)
  }

  /// 窗口标题给「窗口」菜单与辅助功能看，折叠后也显示在标题栏里：取第一行文字，空便笺叫「便笺」。
  private func updateTitle() {
    let title = center?.note(id: noteID)?.title ?? ""
    window?.title = title.isEmpty ? L("便笺") : title
    collapsedTitle.stringValue = title
  }

  /// 存下来的位置还落在某块屏幕上（显示器拔掉后不再用旧位置）。
  private static func isOnScreen(_ frame: StickyNoteFrame) -> Bool {
    let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
  }

  // MARK: - 折叠

  /// 双击标题栏：折叠成只剩标题栏，或展开回原来的高度。
  private func toggleCollapsed() {
    setCollapsed(expandedHeight == nil, animate: true)
    center?.setCollapsed(expandedHeight != nil, id: noteID)
  }

  /// 折叠时顶边不动、高度收成标题栏，不能改大小；展开时恢复折叠前的高度。
  private func setCollapsed(_ collapsed: Bool, animate: Bool) {
    guard let window, collapsed != (expandedHeight != nil) else { return }
    let frame = window.frame
    let height: CGFloat
    if collapsed {
      expandedHeight = frame.height
      height = titlebarHeight
      window.styleMask.remove(.resizable)
      window.minSize = NSSize(width: 160, height: titlebarHeight)
    } else {
      height = expandedHeight ?? StickyNoteCenter.defaultSize.height
      expandedHeight = nil
      window.styleMask.insert(.resizable)
      window.minSize = NSSize(width: 160, height: 100)
    }
    scroll.isHidden = collapsed
    collapsedTitle.isHidden = !collapsed
    let target = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    let animated = animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window.isVisible
    window.setFrame(target, display: true, animate: animated)
    if !collapsed { window.makeFirstResponder(textView) }
  }

  // MARK: - 命令

  /// 执行快捷键或菜单命令。
  private func perform(_ command: StickyNoteCommand) {
    guard let center, let note = center.note(id: noteID) else { return }
    switch command {
    case .newNote: center.createNote()
    case .showFonts:
      window?.makeFirstResponder(textView)
      NSFontManager.shared.orderFrontFontPanel(nil)
    case .bold: StickyNoteFormatter.toggle(.boldFontMask, in: textView)
    case .italic: StickyNoteFormatter.toggle(.italicFontMask, in: textView)
    case .underline: textView.underline(nil)
    case .bigger: StickyNoteFormatter.adjustSize(by: 1, in: textView)
    case .smaller: StickyNoteFormatter.adjustSize(by: -1, in: textView)
    case .color(let color): center.setColor(color, id: noteID)
    case .floatOnTop: center.setFloatsOnTop(!note.floatsOnTop, id: noteID)
    case .translucent: center.setTranslucent(!note.isTranslucent, id: noteID)
    }
  }

  /// 菜单项：标题 + 快捷键提示，点了执行命令。
  private func menuItem(_ title: String, _ command: StickyNoteCommand) -> NSMenuItem {
    let item = ActionMenuItem(title: title) { [weak self] in self?.perform(command) }
    let equivalent = command.keyEquivalent
    item.keyEquivalent = equivalent.key
    item.keyEquivalentModifierMask = equivalent.modifiers
    return item
  }

  /// 正文右键菜单里便笺自己的几项，放在系统编辑菜单的上面。
  private func noteMenuItems() -> [NSMenuItem] {
    guard let note = center?.note(id: noteID) else { return [] }
    let fonts = NSMenu(title: L("字体"))
    for item in [
      menuItem(L("显示字体"), .showFonts), menuItem(L("粗体"), .bold), menuItem(L("斜体"), .italic),
      menuItem(L("下划线"), .underline), .separator(), menuItem(L("变大"), .bigger), menuItem(L("变小"), .smaller),
    ] {
      fonts.addItem(item)
    }
    let fontItem = NSMenuItem(title: L("字体"), action: nil, keyEquivalent: "")
    fontItem.submenu = fonts
    let colors = NSMenu(title: L("颜色"))
    for color in StickyNoteColor.allCases {
      let item = menuItem(StickyNotePalette.name(color), .color(color))
      item.image = StickyNotePalette.swatch(color)
      item.state = color == note.color ? .on : .off
      colors.addItem(item)
    }
    let colorItem = NSMenuItem(title: L("颜色"), action: nil, keyEquivalent: "")
    colorItem.submenu = colors
    let floatItem = menuItem(L("浮在最前面"), .floatOnTop)
    floatItem.state = note.floatsOnTop ? .on : .off
    let translucentItem = menuItem(L("半透明"), .translucent)
    translucentItem.state = note.isTranslucent ? .on : .off
    let collapseItem = ActionMenuItem(title: L("折叠便笺")) { [weak self] in self?.toggleCollapsed() }
    let deleteItem = ActionMenuItem(title: L("删除便笺…")) { [weak self] in self?.confirmDelete() }
    return [
      menuItem(L("新建便笺"), .newNote), .separator(), fontItem, colorItem, .separator(), floatItem, translucentItem,
      collapseItem, .separator(), deleteItem,
    ]
  }

  /// 删除前确认；空便笺直接删。
  private func confirmDelete() {
    guard let window, let center else { return }
    let text = center.note(id: noteID)?.text ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      center.delete(id: noteID)
      return
    }
    let alert = NSAlert()
    alert.messageText = L("删除这张便笺？")
    alert.informativeText = L("删除后无法恢复。只想让它从桌面上消失，点左上角的关闭按钮即可。")
    alert.addButton(withTitle: L("删除"))
    alert.addButton(withTitle: L("取消"))
    alert.buttons.first?.hasDestructiveAction = true
    let id = noteID
    alert.beginSheetModal(for: window) { [weak center] response in
      guard response == .alertFirstButtonReturn else { return }
      MainActor.assumeIsolated { center?.delete(id: id) }
    }
  }

  // MARK: - NSTextViewDelegate

  /// 正文右键菜单：便笺自己的几项放在系统编辑菜单上面。
  func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
    let items = noteMenuItems()
    guard !items.isEmpty else { return menu }
    menu.insertItem(.separator(), at: 0)
    for item in items.reversed() { menu.insertItem(item, at: 0) }
    return menu
  }

  /// 每次改字或改格式都把纯文本与整篇 RTF 交给便笺中心（由它去抖保存），并刷新标题。
  func textDidChange(_ notification: Notification) {
    guard let storage = textView.textStorage else { return }
    let fullRange = NSRange(location: 0, length: storage.length)
    let rich = storage.length == 0 ? nil : storage.rtf(from: fullRange, documentAttributes: [:])
    center?.noteTextDidChange(id: noteID, text: textView.string, richText: rich)
    updateTitle()
  }

  // MARK: - NSWindowDelegate

  func windowDidMove(_ notification: Notification) { commitPendingFrame() }

  func windowDidEndLiveResize(_ notification: Notification) { commitPendingFrame() }

  /// 用户关窗口：记下位置，标成已隐藏。删除时不回写。
  func windowWillClose(_ notification: Notification) {
    guard !isClosingWithoutSaving else { return }
    commitPendingFrame()
    center?.noteWindowDidClose(id: noteID)
  }
}
