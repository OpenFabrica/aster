// 一张便笺的窗口：彩色纸面、无标题文字的细标题栏、整块可编辑的正文。右键菜单里新建、换颜色、浮在最前面与删除。
// 纸面固定浅色（与 macOS「便笺」一致），不随 App 的深色外观变黑。改动交给 StickyNoteCenter 保存。
import AppKit
import AsterCore

/// 一张便笺的窗口控制器。只由 `StickyNoteCenter` 创建与持有。
@MainActor
final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
  /// 正文上方留给标题栏（关闭按钮）的高度。
  private static let titlebarHeight: CGFloat = 24

  let noteID: UUID
  private weak var center: StickyNoteCenter?
  /// 系统配好的滚动文本区：正文铺满可见区域，点空白处也能把光标放进去。
  private let scroll = NSTextView.scrollableTextView()
  private let textView: NSTextView
  private let paper = StickyNoteFillView()
  private let titlebarStrip = StickyNoteFillView()
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
    super.init(window: window)
    window.delegate = self
    window.onNewNote = { [weak center] in center?.createNote() }
    window.contentView = makeContent()
    textView.string = note.text
    textView.delegate = self
    apply(color: note.color)
    apply(floatsOnTop: note.floatsOnTop)
    updateTitle()
    if let frame = note.frame, Self.isOnScreen(frame) {
      window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
    } else {
      window.center()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 正文滚动区占满标题栏以下；顶上一条略深的色带当标题栏，可以拖动窗口。
  private func makeContent() -> NSView {
    // 纸面由视图自己画：窗口背景色在透明标题栏下的混合方式随系统版本变化，颜色不稳。
    let root = paper
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    textView.isRichText = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.font = NSFont.interface(ofSize: 13)
    textView.textColor = NSColor(white: 0.12, alpha: 1)
    textView.insertionPointColor = NSColor(white: 0.12, alpha: 1)
    textView.textContainerInset = NSSize(width: 8, height: 6)
    textView.setAccessibilityLabel(L("便笺"))
    for view in [titlebarStrip, scroll] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    NSLayoutConstraint.activate([
      titlebarStrip.topAnchor.constraint(equalTo: root.topAnchor),
      titlebarStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      titlebarStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      titlebarStrip.heightAnchor.constraint(equalToConstant: Self.titlebarHeight),
      scroll.topAnchor.constraint(equalTo: titlebarStrip.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    return root
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

  /// 删除便笺时关窗口：不再回写「已隐藏」。
  func closeWithoutSaving() {
    isClosingWithoutSaving = true
    window?.close()
  }

  /// 把当前位置写回（App 退出前）。
  func commitPendingFrame() {
    guard let window, window.isVisible else { return }
    center?.noteFrameDidChange(id: noteID, frame: window.frame)
  }

  /// 窗口标题只给「窗口」菜单与辅助功能看：取第一行文字，空便笺叫「便笺」。
  private func updateTitle() {
    let title = center?.note(id: noteID)?.title ?? ""
    window?.title = title.isEmpty ? L("便笺") : title
  }

  /// 存下来的位置还落在某块屏幕上（显示器拔掉后不再用旧位置）。
  private static func isOnScreen(_ frame: StickyNoteFrame) -> Bool {
    let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    return NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
  }

  // MARK: - 菜单

  /// 正文右键菜单里便笺自己的几项，放在系统编辑菜单的上面。
  private func noteMenuItems() -> [NSMenuItem] {
    guard let note = center?.note(id: noteID) else { return [] }
    let newItem = ActionMenuItem(title: L("新建便笺")) { [weak center] in center?.createNote() }
    let colorItem = NSMenuItem(title: L("颜色"), action: nil, keyEquivalent: "")
    let colors = NSMenu(title: L("颜色"))
    for color in StickyNoteColor.allCases {
      let item = ActionMenuItem(title: StickyNotePalette.name(color)) { [weak self] in
        guard let self else { return }
        self.center?.setColor(color, id: self.noteID)
      }
      item.image = StickyNotePalette.swatch(color)
      item.state = color == note.color ? .on : .off
      colors.addItem(item)
    }
    colorItem.submenu = colors
    let floatItem = ActionMenuItem(title: L("浮在最前面")) { [weak self] in
      guard let self else { return }
      self.center?.setFloatsOnTop(!note.floatsOnTop, id: self.noteID)
    }
    floatItem.state = note.floatsOnTop ? .on : .off
    let deleteItem = ActionMenuItem(title: L("删除便笺…")) { [weak self] in self?.confirmDelete() }
    return [newItem, colorItem, floatItem, .separator(), deleteItem]
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

  /// 每次改动都交给便笺中心（由它去抖保存），并刷新窗口标题。
  func textDidChange(_ notification: Notification) {
    center?.noteTextDidChange(id: noteID, text: textView.string)
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

// MARK: - 窗口与视图

/// 便笺窗口：在便笺里按 `⌘N` 新建便笺，而不是新建工作区窗口。
@MainActor
final class StickyNoteWindow: ToolStandaloneWindow {
  var onNewNote: (() -> Void)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "n", let onNewNote {
      onNewNote()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// 纯色块：纸面与顶部色带（比纸面略深，当作标题栏，点在这里可以拖动窗口）。
@MainActor
final class StickyNoteFillView: NSView {
  var color: NSColor = .clear {
    didSet { needsDisplay = true }
  }

  override var mouseDownCanMoveWindow: Bool { true }

  /// 只填自己的范围：macOS 14 起视图默认不裁剪，`dirtyRect` 可能超出 bounds，直接填会盖住兄弟视图。
  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    bounds.intersection(dirtyRect).fill()
  }
}

/// 便笺的颜色：纸面、色带、名字与菜单色块。纸面取 macOS「便笺」的经典配色。
@MainActor
enum StickyNotePalette {
  /// 纸面颜色。
  static func paper(_ color: StickyNoteColor) -> NSColor {
    let hex: UInt32 =
      switch color {
      case .yellow: 0xFFF9A6
      case .blue: 0xADF4FF
      case .green: 0xB2FFA1
      case .pink: 0xFFC7C7
      case .purple: 0xD6CCFF
      case .gray: 0xEEEEEE
      }
    return NSColor(
      srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }

  /// 顶部色带：纸面压暗一点。
  static func strip(_ color: StickyNoteColor) -> NSColor {
    paper(color).blended(withFraction: 0.05, of: .black) ?? paper(color)
  }

  /// 菜单里显示的名字。
  static func name(_ color: StickyNoteColor) -> String {
    switch color {
    case .yellow: L("黄色")
    case .blue: L("蓝色")
    case .green: L("绿色")
    case .pink: L("粉色")
    case .purple: L("紫色")
    case .gray: L("灰色")
    }
  }

  /// 菜单与列表用的小圆色块。
  static func swatch(_ color: StickyNoteColor, diameter: CGFloat = 12) -> NSImage {
    let paperColor = paper(color)
    let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
      let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
      paperColor.setFill()
      path.fill()
      NSColor(white: 0, alpha: 0.25).setStroke()
      path.lineWidth = 1
      path.stroke()
      return true
    }
    image.isTemplate = false
    return image
  }
}
