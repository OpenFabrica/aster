import AppKit
import AsterCore
import Testing
@testable import Aster

@MainActor
private struct PaneHeaderFixture {
  let model: AppModel
  let tab: TerminalTabItem
  let controller: WorkspaceTitlePopoverViewController
  let window: NSWindow

  init() throws {
    let defaults = UserDefaults(suiteName: "PaneHeaderTests.\(UUID())")!
    let snapshot = WorkspaceTabSnapshot(id: UUID(), title: "fixture",
      layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")))
    defaults.set(try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshot.id,
      tabs: [snapshot])), forKey: "aster.workspace.snapshot.v1")
    model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    tab = try #require(model.selectedTab)
    controller = WorkspaceTitlePopoverViewController(model: model,
      preferences: AppPreferences(defaults: defaults), tab: tab)
    controller.pasteboard = NSPasteboard.withUniqueName()
    window = NSWindow(contentRect: NSRect(origin: .zero,
      size: WorkspaceTitlePopoverViewController.preferredSize),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  func button(_ id: String) throws -> WorkspaceTitleRowButton {
    try #require(controller.view.paneDescendants.compactMap { $0 as? WorkspaceTitleRowButton }
      .first { $0.identifier?.rawValue == id })
  }

  func finish() {
    controller.menuPresenter.close()
    window.orderOut(nil)
    controller.pasteboard.releaseGlobally()
  }
}

private extension NSView {
  var paneDescendants: [NSView] { subviews + subviews.flatMap(\.paneDescendants) }
}

@Test @MainActor func paneHeaderHoverOpensAndSwitchesSubmenusWithoutClick() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
    modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber,
    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
  let split = try f.button("workspace-title-split")
  split.mouseEntered(with: event)
  let first = try #require(f.controller.menuPresenter.panel)
  #expect(first.isVisible)
  #expect(split.submenuIsPresented)
  #expect(first.parent === f.window)
  let about = try f.button("workspace-title-about")
  about.mouseEntered(with: event)
  #expect(!first.isVisible)
  #expect(!split.submenuIsPresented)
  #expect(about.submenuIsPresented)
  #expect(f.controller.menuPresenter.panel?.contentView?.paneDescendants.contains {
    ($0 as? NSTextField)?.stringValue.contains(f.controller.paneID.uuidString) == true
  } == true)
  try f.button("workspace-title-find").mouseEntered(with: event)
  #expect(f.controller.menuPresenter.panel == nil)
}

@Test @MainActor func paneHeaderSplitsCapturedPaneAndRejectsStaleTarget() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let menu = f.controller.splitMenu()
  #expect(menu.items.compactMap(\.identifier).map(\.rawValue) == [
    "pane-split-right", "pane-split-left", "pane-split-down", "pane-split-up"])
  let item = try #require(menu.items.first)
  NSApp.sendAction(try #require(item.action), to: item.target, from: item)
  #expect(f.tab.layout.allPanes.count == 2)
  #expect(f.tab.activePaneID != f.controller.paneID)
  #expect(!f.controller.targetIsCurrent)
  NSApp.sendAction(try #require(item.action), to: item.target, from: item)
  #expect(f.tab.layout.allPanes.count == 2)
}

@Test @MainActor func paneHeaderNamesPersistAndModesDoNotSubmit() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let field = try #require(f.controller.view.paneDescendants.compactMap { $0 as? NSTextField }
    .first { $0.identifier?.rawValue == "workspace-title-name-field" })
  let mode = try #require(f.controller.view.paneDescendants.compactMap { $0 as? NSSegmentedControl }.first)
  field.stringValue = "  Work  "
  NSApp.sendAction(try #require(field.action), to: field.target, from: field)
  #expect(f.tab.tabTitleOverride == .name("Work"))
  mode.selectedSegment = 1
  NSApp.sendAction(try #require(mode.action), to: mode.target, from: mode)
  #expect(field.stringValue.isEmpty)
  #expect(f.tab.tabTitleOverride == .name("Work"))
  field.stringValue = "dev: "
  NSApp.sendAction(try #require(field.action), to: field.target, from: field)
  let restored = TerminalTabItem(snapshot: f.tab.snapshot)
  #expect(restored.titleEditorState.name == "Work")
  #expect(restored.titleEditorState.prefix == "dev: ")
  let reset = try #require(f.controller.view.paneDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "workspace-title-reset-name" })
  reset.performClick(nil)
  #expect(f.tab.tabTitleOverride == .automatic)
  #expect(mode.selectedSegment == 0)
  #expect(field.stringValue.isEmpty)
}

@Test @MainActor func paneHeaderCopyUsesPaneIdentityAndDirectory() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  f.controller.copyPath()
  #expect(f.controller.pasteboard.string(forType: .string) == "/tmp")
  let copy = try #require(f.controller.aboutMenu().items.last)
  NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy)
  #expect(f.controller.pasteboard.string(forType: .string) == f.tab.activePaneID.uuidString)
  #expect(f.controller.displayDirectory == "/tmp/")
}

@Test @MainActor func paneHeaderNameSwitchUsesAutomaticTitleAfterPrefixSubmission() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let field = try #require(f.controller.view.paneDescendants.compactMap { $0 as? NSTextField }
    .first { $0.identifier?.rawValue == "workspace-title-name-field" })
  let mode = try #require(f.controller.view.paneDescendants.compactMap { $0 as? NSSegmentedControl }.first)
  func select(_ index: Int) throws {
    mode.selectedSegment = index
    NSApp.sendAction(try #require(mode.action), to: mode.target, from: mode)
  }
  f.tab.applyProgramTitle(code: 0, text: "automatic-title")
  field.stringValue = "Work"
  NSApp.sendAction(try #require(field.action), to: field.target, from: field)
  try select(1)
  try select(0)
  #expect(field.stringValue == "Work") // Prefix 未提交，生效的仍是固定名称。
  try select(1)
  field.stringValue = "dev: "
  NSApp.sendAction(try #require(field.action), to: field.target, from: field)
  try select(0)
  #expect(field.stringValue == "automatic-title")
  #expect(f.tab.tabTitleOverride == .prefix("dev: ")) // 切换本身不提交。
  #expect(f.tab.titleEditorState.name == "Work")
  field.stringValue = "unsubmitted draft"
  try select(0)
  #expect(field.stringValue == "unsubmitted draft") // 重点同一模式不清草稿。
  f.tab.applyProgramTitle(code: 0, text: "")
  try select(1)
  try select(0)
  #expect(field.stringValue.isEmpty) // 不把 cwd 回退或带前缀的标题填进来。
}

@Test @MainActor func paneHeaderPrivilegesAreSharedWithinTabAndIsolatedAcrossTabs() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let first = try #require(f.tab.activeSession)
  f.tab.split(direction: .right)
  let second = try #require(f.tab.activeSession)
  let other = TerminalTabItem(title: "other", workingDirectory: "/tmp")
  first.privilegesState.set(.terminalBell, to: false)
  #expect(first.privilegesState === second.privilegesState)
  #expect(second.privilegesState.userOverrides[.terminalBell] == false)
  #expect(other.activeSession?.privilegesState.userOverrides[.terminalBell] == nil)
}

@Test @MainActor func paneHeaderKeyboardKeepsLongMenuSelectionVisibleAndRightDoesNotExecuteLeaf() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let menu = NSMenu()
  menu.autoenablesItems = false
  var executed: [Int] = []
  for index in 0..<80 {
    let item = ActionMenuItem(title: "Branch \(index)") { executed.append(index) }
    item.identifier = NSUserInterfaceItemIdentifier("keyboard-\(index)")
    menu.addItem(item)
  }
  let presenter = f.controller.menuPresenter
  presenter.show(menu, from: try f.button("workspace-title-split"))
  presenter.focusFirstItem()
  func key(_ code: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: f.window.windowNumber, context: nil,
      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  #expect(presenter.handleKey(try key(124)))
  #expect(executed.isEmpty)
  for _ in 0..<79 { _ = presenter.handleKey(try key(125)) }
  let last = try #require(presenter.panel?.contentView?.paneDescendants.first {
    $0.identifier?.rawValue == "keyboard-79"
  })
  #expect(!last.visibleRect.isEmpty)
  #expect(presenter.handleKey(try key(36)))
  #expect(executed == [79])
}

@Test @MainActor func paneHeaderTabLeavesNameEditorWithoutSystemFullKeyboardAccess() throws {
  let f = try PaneHeaderFixture()
  defer { f.finish() }
  let field = try #require(f.controller.view.paneDescendants.compactMap { $0 as? NSTextField }
    .first { $0.identifier?.rawValue == "workspace-title-name-field" })
  let handled = f.controller.control(field, textView: NSTextView(),
    doCommandBy: #selector(NSResponder.insertTab(_:)))
  #expect(handled)
  #expect(f.window.firstResponder === (try f.button("workspace-title-copy-path")))
}
