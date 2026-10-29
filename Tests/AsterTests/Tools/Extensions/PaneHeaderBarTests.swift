// 界面扩展 pane.header：图标组只放图标、最多 3 个，文字进提示；隐藏时不拦截点击。挂到真实工作区时每个终端
// Pane 一组（文件 Pane 不挂），跨整树重建是同一实例，排在顶条自带按钮左边、随顶条一起淡入；和 pane.bottom
// 共用 Pane 的上下文，停掉其中一种不影响另一种。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：Pane 顶部")
struct PaneHeaderBarTests {
  /// 装进窗口的工作区与它的假视图目录。
  @MainActor
  private struct Fixture {
    let window: NSWindow
    let workspace: WorkspaceViewController
    let catalog: FakeToolViewCatalog

    var host: WorkspaceExtensionHost { workspace.extensionHost }

    /// 关窗并停掉扩展宿主。
    func close() {
      workspace.extensionHost.teardown()
      window.close()
    }
  }

  /// 两个终端 Pane（不同目录）加一个文件 Pane。
  private struct Panes {
    let a: PaneDescriptor
    let b: PaneDescriptor
    let files: PaneDescriptor
  }

  /// 按给定视图与「两个终端 + 一个文件 Pane」的标签建工作区窗口。
  private func makeFixture(entries: [ToolViewEntry]) throws -> (Fixture, Panes) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-pane-header-\(UUID().uuidString)", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let panes = Panes(
      a: PaneDescriptor(kind: .terminal, workingDirectory: first.path),
      b: PaneDescriptor(kind: .terminal, workingDirectory: second.path),
      files: PaneDescriptor(kind: .fileBrowser, workingDirectory: root.path))
    let layout = PaneLayout.split(
      axis: .horizontal, first: .leaf(panes.a),
      second: .split(axis: .vertical, first: .leaf(panes.b), second: .leaf(panes.files), ratio: 0.5), ratio: 0.5)

    let suite = "PaneHeaderBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let tab = WorkspaceTabSnapshot(id: UUID(), title: "Panes", layout: layout)
    defaults.set(
      try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
      forKey: "aster.workspace.snapshot.v1")
    let model = AppModel(defaults: defaults)
    let preferences = AppPreferences(defaults: defaults)
    model.ensureInitialTab()
    let catalog = FakeToolViewCatalog()
    catalog.viewEntries = entries
    let workspace = WorkspaceViewController(model: model, preferences: preferences, toolViewCatalog: catalog)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = workspace
    window.contentView?.layoutSubtreeIfNeeded()
    return (Fixture(window: window, workspace: workspace, catalog: catalog), panes)
  }

  /// 视图树里某个 Pane 的宿主。
  private func paneHost(_ paneID: UUID, in root: NSView) -> ActivePaneHostView? {
    if let host = root as? ActivePaneHostView, host.paneID == paneID { return host }
    for subview in root.subviews {
      if let host = paneHost(paneID, in: subview) { return host }
    }
    return nil
  }

  /// 一段只有项目的内容。
  private func segment(_ id: String, _ items: [ToolBarItem]) -> ToolBarSegment {
    ToolBarSegment(id: id, pluginName: "Test", iconPath: nil, content: .items(items), runningSince: nil)
  }

  @Test("图标组：跨段只取前 3 个有图标的项目，纯文字项目不显示，文字进提示；隐藏时不拦截点击")
  func headerShowsAtMostThreeIconsAndIgnoresClicksWhenHidden() throws {
    let header = ToolPaneHeaderView()
    header.apply(segments: [
      segment("one", [
        ToolBarItem(id: "text", text: "只有文字"),
        ToolBarItem(id: "branch", text: "main", symbol: "arrow.triangle.branch"),
        ToolBarItem(id: "copy", symbol: "doc.on.doc", tooltip: "复制"),
      ]),
      segment("two", [
        ToolBarItem(id: "refresh", symbol: "arrow.clockwise"),
        ToolBarItem(id: "fourth", symbol: "star"),
      ]),
    ])
    let buttons = header.visibleButtons
    #expect(buttons.count == ToolPaneHeaderView.maximumButtons)
    // 第一个按钮是 branch：文字不显示，没写 tooltip 时提示用文字。
    #expect(buttons.first?.toolTip == "main")
    #expect(buttons.dropFirst().first?.toolTip == "复制")
    #expect(buttons.allSatisfy { !$0.showsLabel })

    header.frame = NSRect(x: 0, y: 0, width: 120, height: 14)
    header.layoutSubtreeIfNeeded()
    let inside = NSPoint(x: buttons[0].frame.midX, y: 7)
    #expect(header.hitTest(inside) == nil)
    header.isRevealed = true
    #expect(header.hitTest(inside) != nil)
  }

  @Test("pane.header：每个终端 Pane 一组（文件 Pane 不挂），跨整树重建是同一实例，随顶条淡入；停用后撤下")
  func paneHeaderMountsPerTerminalPaneAndFollowsChromeReveal() async throws {
    let (fixture, panes) = try makeFixture(entries: [makeToolViewEntry(slot: .paneHeader)])
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let hostA = try #require(paneHost(panes.a.id, in: root))
    let headerA = try #require(fixture.host.existingPaneHeader(for: panes.a.id))
    let headerB = try #require(fixture.host.existingPaneHeader(for: panes.b.id))
    #expect(headerA !== headerB)
    #expect(hostA.installedHeaderBar === headerA)
    #expect(paneHost(panes.b.id, in: root)?.installedHeaderBar === headerB)
    #expect(paneHost(panes.files.id, in: root)?.installedHeaderBar == nil)
    #expect(fixture.host.existingPaneHeader(for: panes.files.id) == nil)
    // 只挂顶条图标，不建底部条。
    #expect(fixture.host.existingPaneBar(for: panes.a.id) == nil)

    // 指针进 / 出顶边感应带：图标组跟着自带按钮一起显隐。
    hostA.layoutSubtreeIfNeeded()
    hostA.updateChromeReveal(pointerInView: NSPoint(x: hostA.bounds.midX, y: hostA.bounds.height - 4))
    #expect(headerA.isRevealed)
    hostA.updateChromeReveal(pointerInView: NSPoint(x: hostA.bounds.midX, y: hostA.bounds.midY))
    #expect(!headerA.isRevealed)
    // 贴着顶边，在 Pane 右上角（自带按钮左边）。
    #expect(abs(headerA.frame.maxY - hostA.bounds.maxY) < 0.5)
    #expect(headerA.frame.maxX < hostA.bounds.maxX && headerA.frame.maxX > hostA.bounds.midX)

    fixture.workspace.scheduleRefresh()
    await pollUntil { paneHost(panes.a.id, in: root).map { $0 !== hostA } ?? false }
    let newHostA = try #require(paneHost(panes.a.id, in: root))
    #expect(newHostA.installedHeaderBar === headerA)
    #expect(hostA.installedHeaderBar == nil)

    fixture.catalog.viewEntries = [makeToolViewEntry(slot: .paneHeader, isEnabled: false)]
    fixture.catalog.send()
    #expect(fixture.host.existingPaneHeader(for: panes.a.id) == nil)
    await pollUntil { paneHost(panes.a.id, in: root)?.installedHeaderBar == nil }
    #expect(paneHost(panes.a.id, in: root)?.installedHeaderBar == nil)
    #expect(headerA.superview == nil)
  }

  @Test("pane.header 与 pane.bottom 共用 Pane 上下文；停掉顶部只撤图标组，底部条与上下文都在")
  func paneHeaderAndBottomShareContext() async throws {
    let header = makeToolViewEntry(viewID: "header", slot: .paneHeader)
    let bottom = makeToolViewEntry(viewID: "bottom", slot: .paneBottom)
    let (fixture, panes) = try makeFixture(entries: [header, bottom])
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let bar = try #require(fixture.host.existingPaneBar(for: panes.b.id))
    #expect(fixture.host.existingPaneHeader(for: panes.b.id) != nil)
    #expect(fixture.host.paneContext(for: panes.b.id)?.workingDirectory == panes.b.workingDirectory)
    let headerKey = ToolBarScheduler.paneFeedKey(entryID: header.id, paneID: panes.b.id)
    #expect(fixture.host.scheduler.feed(id: headerKey)?.context.workingDirectory == panes.b.workingDirectory)

    fixture.catalog.viewEntries = [makeToolViewEntry(viewID: "header", slot: .paneHeader, isEnabled: false), bottom]
    fixture.catalog.send()
    #expect(fixture.host.existingPaneHeader(for: panes.b.id) == nil)
    #expect(fixture.host.existingPaneBar(for: panes.b.id) === bar)
    #expect(fixture.host.paneContext(for: panes.b.id) != nil)
    #expect(fixture.host.scheduler.feed(id: headerKey) == nil)
    await pollUntil { paneHost(panes.b.id, in: root)?.installedHeaderBar == nil }
    #expect(paneHost(panes.b.id, in: root)?.installedExtensionBar === bar)
  }
}
