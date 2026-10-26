import AppKit
import AsterCore

/// 只缩进原生按钮内容，保留整行背景、鼠标命中与 tracking 范围。
private final class PaneMenuRowCell: NSButtonCell {
  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    super.drawInterior(withFrame: cellFrame.insetBy(dx: 10, dy: 0), in: controlView)
  }
}

/// Nonmodal menu rows keep the parent panel tracking pointer movement while a submenu is open.
@MainActor
final class WorkspaceTitleRowButton: NSButton {
  var onHover: ((WorkspaceTitleRowButton) -> Void)?
  var onKey: ((NSEvent) -> Bool)?
  let hasSubmenu: Bool
  var submenuIsPresented = false { didSet { updateHighlight() } }
  private let handler: (WorkspaceTitleRowButton) -> Void
  private var tracking: NSTrackingArea?
  private var hovered = false
  private var accessoryLabels: [NSTextField] = []
  private var accessoryIcons: [NSImageView] = []
  override var isEnabled: Bool { didSet { updateHighlight() } }

  func setStatusSymbols(_ symbols: [String]) {
    for (icon, name) in zip(accessoryIcons, symbols.reversed()) {
      icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
  }

  init(
    title: String, symbol: String? = nil, shortcut: String? = nil,
    trailingSymbols: [String] = [], showsSubmenu: Bool = false,
    handler: @escaping (WorkspaceTitleRowButton) -> Void
  ) {
    self.handler = handler
    self.hasSubmenu = showsSubmenu
    super.init(frame: .zero)
    cell = PaneMenuRowCell(textCell: title)
    self.title = title
    isBordered = false
    alignment = .left
    font = NSFont.interface(ofSize: 13.5)
    lineBreakMode = .byTruncatingMiddle
    wantsLayer = true
    layer?.cornerRadius = 6
    target = self
    action = #selector(invoke)
    setAccessibilityLabel(title)
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      imagePosition = .imageLeading
    }
    if let text = shortcut ?? (showsSubmenu ? "›" : nil) {
      let label = makeLabel(text, size: 11.5, color: .secondaryLabelColor)
      label.alignment = .right
      label.setAccessibilityElement(false)
      accessoryLabels.append(label)
      addSubview(label)
      label.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        label.centerYAnchor.constraint(equalTo: centerYAnchor),
        label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      ])
    }
    for (index, symbol) in trailingSymbols.reversed().enumerated() {
      let icon = NSImageView(image: NSImage(systemSymbolName: symbol,
        accessibilityDescription: nil) ?? NSImage())
      icon.setAccessibilityElement(false)
      accessoryIcons.append(icon)
      addSubview(icon)
      icon.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.trailingAnchor.constraint(equalTo: trailingAnchor,
          constant: -CGFloat(26 + index * 21)),
        icon.widthAnchor.constraint(equalToConstant: InterfaceScale.length(13)),
        icon.heightAnchor.constraint(equalToConstant: InterfaceScale.length(13)),
      ])
    }
    updateHighlight()
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { isEnabled }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
    if let tracking { addTrackingArea(tracking) }
  }

  override func mouseEntered(with event: NSEvent) {
    guard isEnabled else { return }
    hovered = true
    updateHighlight()
    onHover?(self)
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    updateHighlight()
  }

  override func keyDown(with event: NSEvent) {
    if onKey?(event) == true { return }
    switch event.keyCode {
    case 36, 49: performClick(nil)
    case 124: if hasSubmenu { performClick(nil) }
    case 125: window?.selectNextKeyView(self)
    case 126: window?.selectPreviousKeyView(self)
    default: super.keyDown(with: event)
    }
  }

  private func updateHighlight() {
    let selected = isEnabled && (hovered || submenuIsPresented)
    layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.cgColor : nil
    let color: NSColor = selected ? .white : (isEnabled ? .labelColor : .disabledControlTextColor)
    contentTintColor = color
    attributedTitle = NSAttributedString(string: title, attributes: [
      .foregroundColor: color, .font: font ?? NSFont.systemFont(ofSize: 13.5),
    ])
    for label in accessoryLabels { label.textColor = selected ? .white : .secondaryLabelColor }
    for icon in accessoryIcons { icon.contentTintColor = selected ? .white : .secondaryLabelColor }
    needsDisplay = true
  }

  @objc private func invoke() { handler(self) }
}

private final class PaneSubmenuPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Renders an NSMenu as a child window without entering AppKit's modal menu tracking loop.
/// This lets hover switch between parent rows and keeps text editing in the parent popover.
@MainActor
final class PaneMenuPresenter {
  private(set) var panel: NSPanel?
  private var child: PaneMenuPresenter?
  private weak var anchor: WorkspaceTitleRowButton?
  private var retainedMenu: NSMenu?
  private var itemRows: [WorkspaceTitleRowButton] = []
  private var keyboardIndex: Int?
  private(set) var hasKeyboardFocus = false
  var beforeAction: (() -> Bool)?
  var afterAction: (() -> Void)?

  func isPresenting(_ row: WorkspaceTitleRowButton) -> Bool { anchor === row && panel != nil }

  /// 根弹层判断外部点击时，需要包含所有仍可见的级联窗口。
  func contains(window: NSWindow?) -> Bool {
    guard let window else { return false }
    return (panel === window && panel?.isVisible == true) || child?.contains(window: window) == true
  }

  func show(_ menu: NSMenu, from row: WorkspaceTitleRowButton) {
    guard anchor !== row || panel == nil, let parent = row.window else { return }
    close()
    menu.update()
    retainedMenu = menu
    anchor = row
    row.submenuIsPresented = true
    let width = min(InterfaceScale.length(420), max(InterfaceScale.length(210),
      menu.items.map { item in
        (item.title as NSString).size(withAttributes: [.font: NSFont.interface(ofSize: 13)]).width
          + InterfaceScale.length(64)
      }.max() ?? 210))
    let rowHeight = InterfaceScale.length(28)
    let height = menu.items.reduce(CGFloat(12)) { $0 + ($1.isSeparatorItem ? 9 : rowHeight) }
    let surface = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    surface.identifier = NSUserInterfaceItemIdentifier("pane-cascading-menu")
    surface.material = .menu
    surface.blendingMode = .behindWindow
    surface.state = .active
    surface.wantsLayer = true
    surface.layer?.cornerRadius = 9
    surface.layer?.borderWidth = 0.5
    surface.layer?.borderColor = NSColor.separatorColor.cgColor
    var y = height - 6
    for item in menu.items {
      if item.isSeparatorItem {
        y -= 9
        let line = NSBox(frame: NSRect(x: 12, y: y + 4, width: width - 24, height: 1))
        line.boxType = .separator
        surface.addSubview(line)
        continue
      }
      y -= rowHeight
      if !item.isEnabled && item.action == nil {
        let label = NSTextField(labelWithString: item.title)
        label.font = NSFont.interface(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = item.toolTip ?? item.title
        label.identifier = item.identifier
        let labelHeight = InterfaceScale.length(18)
        label.frame = NSRect(x: 9, y: y + (rowHeight - labelHeight) / 2,
          width: width - 18, height: labelHeight)
        surface.addSubview(label)
        continue
      }
      let row = WorkspaceTitleRowButton(title: item.title,
        shortcut: Self.shortcutLabel(item), showsSubmenu: item.submenu != nil) {
        [weak self] row in
        guard let self else { return }
        if let submenu = item.submenu {
          self.showChild(submenu, from: row)
          if self.hasKeyboardFocus { self.child?.focusFirstItem() }
          return
        }
        guard self.beforeAction?() != false else { return }
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        self.afterAction?()
      }
      row.isEnabled = item.isEnabled
      row.toolTip = item.toolTip
      row.identifier = item.identifier
      row.frame = NSRect(x: 7, y: y, width: width - 14, height: rowHeight)
      if let icon = item.image?.copy() as? NSImage {
        icon.size = NSSize(width: 16, height: 16)
        row.image = icon
        row.imagePosition = .imageLeading
      } else if item.state != .off {
        row.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: L("已启用"))
        row.imagePosition = .imageLeading
      }
      row.onHover = { [weak self] row in
        if let submenu = item.submenu { self?.showChild(submenu, from: row) }
        else { self?.child?.close() }
      }
      itemRows.append(row)
      surface.addSubview(row)
    }
    let screen = parent.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_024, height: 768)
    let visibleHeight = min(height, screen.height - 16)
    let content: NSView
    if visibleHeight < height {
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight))
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false
      scroll.documentView = surface
      scroll.contentView.scroll(to: NSPoint(x: 0, y: height - visibleHeight))
      content = scroll
    } else { content = surface }
    let source = parent.convertToScreen(row.convert(row.bounds, to: nil))
    let x = source.maxX + width + 4 <= screen.maxX ? source.maxX + 4 : source.minX - width - 4
    let origin = NSPoint(x: max(screen.minX, x),
      y: max(screen.minY, min(source.maxY - visibleHeight + 5, screen.maxY - visibleHeight)))
    let panel = PaneSubmenuPanel(contentRect: NSRect(origin: origin, size: content.frame.size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = true
    panel.contentView = content
    parent.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    self.panel = panel
  }

  func focusFirstItem() {
    hasKeyboardFocus = true
    selectKeyboardItem(itemRows.firstIndex(where: \.isEnabled))
  }

  /// Keyboard events stay in the parent key window, so loading and hover remain nonmodal.
  func handleKey(_ event: NSEvent) -> Bool {
    guard panel != nil, hasKeyboardFocus else { return false }
    if child?.hasKeyboardFocus == true, child?.handleKey(event) == true { return true }
    switch event.keyCode {
    case 125, 126:
      let enabled = itemRows.indices.filter { itemRows[$0].isEnabled }
      guard !enabled.isEmpty else { return true }
      let current = enabled.firstIndex(where: { $0 == keyboardIndex }) ?? 0
      let next = (current + (event.keyCode == 125 ? 1 : enabled.count - 1)) % enabled.count
      child?.close()
      selectKeyboardItem(enabled[next])
    case 36, 49:
      if let index = keyboardIndex { itemRows[index].performClick(nil) }
    case 124:
      if let index = keyboardIndex, itemRows[index].hasSubmenu { itemRows[index].performClick(nil) }
    case 123, 53:
      close()
    default: return false
    }
    return true
  }

  private func selectKeyboardItem(_ index: Int?) {
    if let old = keyboardIndex, itemRows.indices.contains(old) {
      itemRows[old].submenuIsPresented = false
    }
    keyboardIndex = index
    if let index {
      itemRows[index].submenuIsPresented = true
      itemRows[index].scrollToVisible(itemRows[index].bounds)
    }
  }

  func close() {
    selectKeyboardItem(nil)
    hasKeyboardFocus = false
    itemRows = []
    child?.close()
    child = nil
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    panel = nil
    anchor?.submenuIsPresented = false
    anchor = nil
    retainedMenu = nil
  }

  private static func shortcutLabel(_ item: NSMenuItem) -> String? {
    guard !item.keyEquivalent.isEmpty else { return nil }
    let flags = item.keyEquivalentModifierMask
    return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
      + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
      + item.keyEquivalent.uppercased()
  }

  private func showChild(_ menu: NSMenu, from row: WorkspaceTitleRowButton) {
    if child == nil {
      child = PaneMenuPresenter()
      child?.beforeAction = beforeAction
      child?.afterAction = afterAction
    }
    child?.show(menu, from: row)
  }
}
