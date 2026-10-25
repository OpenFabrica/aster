// Pane 菜单外部点击关闭及级联窗口内部点击的回归测试。
import AppKit
import AsterCore
import Testing
@testable import Aster

@MainActor
private final class PaneOutsideClickProbe: NSView {
  var clicks = 0
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { clicks += 1 }
  override func rightMouseDown(with event: NSEvent) { clicks += 1 }
  override func otherMouseDown(with event: NSEvent) { clicks += 1 }
}

@MainActor
private struct PaneDismissalFixture {
  let owner: NSWindow
  let anchor: WorkspaceTitleButton
  let popover: WorkspaceTitlePanel
  let controller: WorkspaceTitlePopoverViewController

  init() throws {
    let defaults = try #require(UserDefaults(suiteName: "PaneDismissalTests.\(UUID())"))
    let snapshot = WorkspaceTabSnapshot(id: UUID(), title: "fixture",
      layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")))
    defaults.set(try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshot.id,
      tabs: [snapshot])), forKey: "aster.workspace.snapshot.v1")
    let model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    controller = WorkspaceTitlePopoverViewController(model: model,
      preferences: AppPreferences(defaults: defaults), tab: try #require(model.selectedTab))
    owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 850, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    let popover = WorkspaceTitlePanel(content: controller)
    self.popover = popover
    anchor = WorkspaceTitleButton(programTitle: "fixture", workingDirectory: "/tmp",
      foregroundColor: .labelColor, backgroundColor: nil) { [weak popover] button in
      guard let popover else { return }
      if popover.isShown { popover.close() }
      else { popover.show(relativeTo: button) }
    }
    anchor.frame = NSRect(x: 400, y: 610, width: 80, height: 25)
    owner.contentView?.addSubview(anchor)
    owner.makeKeyAndOrderFront(nil)
    controller.ownerWindow = owner
    controller.toggleAnchor = anchor
    controller.onDismiss = { [weak popover] in popover?.close() }
    popover.show(relativeTo: anchor)
  }

  func splitRow() throws -> WorkspaceTitleRowButton {
    func rows(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(rows) }
    return try #require(rows(controller.view).compactMap { $0 as? WorkspaceTitleRowButton }
      .first { $0.identifier?.rawValue == "workspace-title-split" })
  }

  func click(_ point: NSPoint, in window: NSWindow, type: NSEvent.EventType = .leftMouseDown) throws {
    let event = try #require(NSEvent.mouseEvent(with: type, location: point,
      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
      clickCount: 1, pressure: 1))
    NSApp.sendEvent(event)
    if type == .leftMouseDown { try click(point, in: window, type: .leftMouseUp) }
  }

  func finish() {
    popover.close()
    controller.menuPresenter.close()
    owner.orderOut(nil)
  }
}

@Test("Pane 菜单外部点击同时关闭根弹层和子菜单，并继续传给原目标", arguments: [false, true], [0, 1, 2])
@MainActor func paneHeaderOutsideClickDismissesPopover(hasSubmenu: Bool, button: Int) throws {
  let f = try PaneDismissalFixture()
  defer { f.finish() }
  let probe = PaneOutsideClickProbe(frame: NSRect(x: 10, y: 10, width: 40, height: 40))
  f.owner.contentView?.addSubview(probe)
  if hasSubmenu { f.controller.showSplitMenu(from: try f.splitRow()) }
  let panel = f.controller.menuPresenter.panel
  #expect(f.popover.isShown)
  let type: NSEvent.EventType = button == 0 ? .leftMouseDown : button == 1 ? .rightMouseDown : .otherMouseDown
  try f.click(NSPoint(x: 20, y: 20), in: f.owner, type: type)
  #expect(!f.popover.isShown)
  #expect(panel?.isVisible != true)
  #expect(probe.clicks == 1)
}

@Test("Pane 菜单内部和多级子菜单内点击保留整条菜单，外部点击全部收起")
@MainActor func paneHeaderInsideClickKeepsCascadeOpen() throws {
  let f = try PaneDismissalFixture()
  defer { f.finish() }
  let root = try #require(f.controller.view.window)
  try f.click(f.controller.view.convert(NSPoint(x: 2, y: 2), to: nil), in: root)
  #expect(f.popover.isShown)

  let menu = NSMenu()
  let parent = NSMenuItem(title: "Nested", action: nil, keyEquivalent: "")
  let nested = NSMenu()
  nested.addItem(ActionMenuItem(title: "Leaf") {})
  parent.submenu = nested
  menu.addItem(parent)
  f.controller.menuPresenter.show(menu, from: try f.splitRow())
  let first = try #require(f.controller.menuPresenter.panel)
  try f.click(NSPoint(x: 2, y: 2), in: first)
  #expect(f.popover.isShown && first.isVisible)
  let row = try #require(first.contentView?.subviews.compactMap { $0 as? WorkspaceTitleRowButton }.first)
  row.performClick(nil)
  let second = try #require(first.childWindows?.first)
  try f.click(NSPoint(x: 2, y: 2), in: second)
  #expect(f.popover.isShown && first.isVisible && second.isVisible)
  try f.click(NSPoint(x: 20, y: 20), in: f.owner)
  #expect(!f.popover.isShown && !first.isVisible && !second.isVisible)
}

@Test("Pane 菜单在应用切走时关闭，重复通知不重复执行关闭回调")
@MainActor func paneHeaderApplicationDeactivationDismissesOnce() throws {
  let f = try PaneDismissalFixture()
  defer { f.finish() }
  f.controller.showSplitMenu(from: try f.splitRow())
  let panel = f.controller.menuPresenter.panel
  let popover = f.popover
  var dismissCount = 0
  f.controller.onDismiss = {
    dismissCount += 1
    popover.close()
  }
  NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
  #expect(!popover.isShown && panel?.isVisible != true)
  NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
  #expect(dismissCount == 1)
}

@Test("Pane 菜单再次点击标题入口关闭，不因提前关闭又被重新打开")
@MainActor func paneHeaderEntryMouseClickClosesPopover() throws {
  let f = try PaneDismissalFixture()
  defer { f.finish() }
  f.controller.showSplitMenu(from: try f.splitRow())
  let point = f.anchor.convert(NSPoint(x: f.anchor.bounds.midX, y: f.anchor.bounds.midY), to: nil)
  // NSButton 的 mouseDown 跟踪循环会同步等待 mouseUp，先把释放事件放进队列。
  let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
    windowNumber: f.owner.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  NSApp.postEvent(up, atStart: true)
  try f.click(point, in: f.owner)
  #expect(!f.popover.isShown)
}

@Test("关闭所属窗口会同时回收无箭头菜单与级联子窗口")
@MainActor func paneHeaderOwnerCloseDismissesCascade() throws {
  let f = try PaneDismissalFixture()
  defer { f.finish() }
  f.controller.showSplitMenu(from: try f.splitRow())
  let child = try #require(f.controller.menuPresenter.panel)
  var closeCount = 0
  f.popover.onClose = { closeCount += 1 }
  f.owner.close()
  #expect(!f.popover.isShown && !child.isVisible)
  #expect(f.controller.isDismissing)
  f.popover.close()
  #expect(closeCount == 1)
}
