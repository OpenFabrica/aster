// Files 预览槽在真实工作区窗口里的局部替换：只换槽里的文件控制器，焦点留在详情面板。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 窗口夹具：终端标签、展开的 Files 详情面板和临时文件。
@MainActor
private struct SwapFixture {
  let suite: String
  let defaults: UserDefaults
  let root: URL
  let model: AppModel
  let workspace: WorkspaceViewController
  let window: NSWindow

  init() throws {
    _ = NSApplication.shared
    suite = "WorkspacePreviewSlotSwapTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-slot-swap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("let first = 1\n".utf8).write(to: root.appendingPathComponent("first.swift"))
    try Data("let second = 2\n".utf8).write(to: root.appendingPathComponent("second.swift"))
    let snapshot = WorkspaceTabSnapshot(id: UUID(), title: "Terminal",
      layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: root.path)))
    defaults.set(try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshot.id, tabs: [snapshot])),
      forKey: "aster.workspace.snapshot.v1")
    model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    let preferences = AppPreferences(defaults: defaults)
    preferences.inspectorPresented = true
    preferences.inspectorSection = 3
    workspace = WorkspaceViewController(model: model, preferences: preferences)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = workspace
    window.orderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  var tab: TerminalTabItem { model.selectedTab! }

  /// 预读并放进当前标签的预览槽。
  func show(_ name: String) throws -> PreviewSlotOutcome {
    let preload = try #require(FileDocumentPreload.load(root.appendingPathComponent(name)))
    return tab.showInPreviewSlot(preload, browsingRoot: root.path)
  }

  /// 当前视图树里的 Pane 外框，按 Pane ID 索引。
  func hosts() -> [UUID: ActivePaneHostView] {
    Dictionary(swapDescendants(workspace.view).compactMap { $0 as? ActivePaneHostView }
      .map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// 工作区当前挂着的文件 Pane 控制器。
  func fileControllers() -> [FilePaneViewController] {
    workspace.children.compactMap { $0 as? FilePaneViewController }
  }

  /// 让出主线程，等待 `scheduleRefresh` 与布局完成。
  func settle(_ milliseconds: Int = 300) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 关窗、停运行态并清理偏好与临时目录。
  func tearDown() {
    window.close()
    model.selectedTab?.stop(immediately: true)
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
}

/// 递归列出视图及其全部子视图。
@MainActor
private func swapDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap { swapDescendants($0) }
}

@Test("预览槽换文件时其它 Pane 视图不重建，只替换槽里的文件控制器")
@MainActor
func previewSlotRetargetSwapsOnlySlotController() async throws {
  let fixture = try SwapFixture()
  defer { fixture.tearDown() }
  try await fixture.settle()
  let terminalID = fixture.tab.activePaneID
  guard case .created(let slotID) = try fixture.show("first.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  try await fixture.settle()
  let before = fixture.hosts()
  let terminalHost = try #require(before[terminalID])
  let slotHost = try #require(before[slotID])
  let terminalContent = terminalHost.subviews
  let oldController = try #require(fixture.fileControllers().first)
  #expect(fixture.fileControllers().count == 1)
  #expect(oldController.view.isDescendant(of: slotHost))
  #expect(oldController.sourceTextView?.string == "let first = 1\n")

  #expect(try fixture.show("second.swift") == .retargeted(slotID))
  try await fixture.settle()
  let after = fixture.hosts()
  #expect(after[terminalID] === terminalHost)
  #expect(after[slotID] === slotHost)
  #expect(terminalHost.subviews.elementsEqual(terminalContent) { $0 === $1 })
  let controllers = fixture.fileControllers()
  #expect(controllers.count == 1)
  let newController = try #require(controllers.first)
  #expect(newController !== oldController)
  #expect(oldController.parent == nil)
  #expect(newController.view.isDescendant(of: slotHost))
  #expect(newController.sourceTextView?.string == "let second = 2\n")
  #expect(slotHost.isPreviewSlot)
  #expect(fixture.tab.activePaneID == terminalID)
}

@Test("第一次建预览槽的整树刷新后，详情面板里的键盘焦点保持不动")
@MainActor
func previewSlotCreationKeepsDetailsPanelFocus() async throws {
  let fixture = try SwapFixture()
  defer { fixture.tearDown() }
  try await fixture.settle()
  let table = try #require(swapDescendants(fixture.workspace.view).compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(fixture.window.makeFirstResponder(table))
  #expect(fixture.window.firstResponder === table)
  let terminalID = fixture.tab.activePaneID
  let terminalHostBefore = try #require(fixture.hosts()[terminalID])
  guard case .created = try fixture.show("first.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  try await fixture.settle()
  #expect(fixture.fileControllers().count == 1)
  // 终端外框换了实例，说明确实走了整树刷新，焦点保持才有意义。
  #expect(fixture.hosts()[terminalID] !== terminalHostBefore)
  #expect(table.window === fixture.window)
  #expect(fixture.window.firstResponder === table)
}

@Test("普通拆分换了活动 Pane 时，焦点交给新 Pane 而不是留在详情面板")
@MainActor
func ordinarySplitMovesFocusToNewPane() async throws {
  let fixture = try SwapFixture()
  defer { fixture.tearDown() }
  try await fixture.settle()
  let table = try #require(swapDescendants(fixture.workspace.view).compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(fixture.window.makeFirstResponder(table))
  fixture.tab.split(direction: .right, kind: .editor,
    resourcePath: fixture.root.appendingPathComponent("second.swift").path,
    workingDirectory: fixture.root.path)
  let newPaneID = fixture.tab.activePaneID
  try await fixture.settle()
  let host = try #require(fixture.hosts()[newPaneID])
  let responder = try #require(fixture.window.firstResponder as? NSView)
  #expect(responder !== table)
  #expect(responder.isDescendant(of: host))
}
