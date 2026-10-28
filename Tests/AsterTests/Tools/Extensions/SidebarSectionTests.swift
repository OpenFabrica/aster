// `sidebar.section`：区块挂在侧栏标签之后、留白之前；bar 纵向列表（每项一行、最多 32 项）；panel 用清单高度、
// `ui.setHeight` 夹到 80–400；整树重建复用同一会话；标签栏不是竖排时不挂载、不建 feed、不建会话。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：侧栏区块")
struct SidebarSectionTests {
  /// 装进窗口的工作区与它的假视图目录。
  @MainActor
  private struct Fixture {
    let window: NSWindow
    let workspace: WorkspaceViewController
    let catalog: FakeToolViewCatalog
    let preferences: AppPreferences

    var host: WorkspaceExtensionHost { workspace.extensionHost }
    var root: NSView { window.contentView! }

    /// 关窗并停掉扩展宿主。
    func close() {
      workspace.extensionHost.teardown()
      window.close()
    }
  }

  private func makeFixture(entries: [ToolViewEntry], layout: TabBarLayout = .vertical) -> Fixture {
    let suite = "SidebarSectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let model = AppModel(defaults: defaults)
    let preferences = AppPreferences(defaults: defaults)
    preferences.tabBarLayout = layout
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
    return Fixture(window: window, workspace: workspace, catalog: catalog, preferences: preferences)
  }

  /// 不经工作区、直接建的宿主（注入记录运行器）。
  private func makeHost(
    entries: [ToolViewEntry], runner: RecordingToolBarRunner
  ) -> (WorkspaceExtensionHost, AppModel, FakeToolViewCatalog) {
    let suite = "SidebarSectionTests.host.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let model = AppModel(defaults: defaults)
    let catalog = FakeToolViewCatalog()
    catalog.viewEntries = entries
    let host = WorkspaceExtensionHost(
      model: model, preferences: AppPreferences(defaults: defaults), catalog: catalog, runner: runner.runner)
    return (host, model, catalog)
  }

  /// 侧栏 panel 视图；`height` 是清单里的高度。
  private func panelEntry(viewID: String = "notes", height: Int? = nil) -> ToolViewEntry {
    ToolViewEntry(
      pluginID: "test.side", pluginName: "Side", source: .user,
      contribution: ToolViewContribution(
        id: viewID, title: "便笺 \(viewID)", kind: .panel, slot: .sidebarSection, height: height,
        main: "views/\(viewID).html"),
      slot: .sidebarSection, isEnabled: true, status: .ready, iconPath: nil,
      pluginDirectory: URL(fileURLWithPath: "/tmp/test.side"), permissions: [])
  }

  /// 按 identifier 找视图。
  private func find(_ identifier: String, in root: NSView) -> NSView? {
    if root.identifier?.rawValue == identifier { return root }
    for subview in root.subviews {
      if let match = find(identifier, in: subview) { return match }
    }
    return nil
  }

  /// 视图树里有没有标签行。
  private func containsTabRow(_ view: NSView) -> Bool {
    view is TabRowButton || view.subviews.contains(where: containsTabRow)
  }

  private func items(_ count: Int) -> [ToolBarItem] {
    (0..<count).map { ToolBarItem(text: "item \($0)", action: .refresh) }
  }

  @Test("bar 区块插在侧栏标签列表之后、留白之前，与侧栏同宽；标题是视图名，有项目才显示")
  func sidebarBarSectionMountsBetweenTabsAndSpacer() throws {
    let entry = makeToolViewEntry(viewID: "list", slot: .sidebarSection)
    let fixture = makeFixture(entries: [entry])
    defer { fixture.close() }
    let sections = try #require(find("tool-sidebar-sections", in: fixture.root))
    #expect(sections === fixture.host.sidebarView)
    let column = try #require(sections.superview as? NSStackView)
    let index = try #require(column.arrangedSubviews.firstIndex { $0 === sections })
    #expect(containsTabRow(column.arrangedSubviews[index - 1]), "前一个是标签列表")
    let spacer = column.arrangedSubviews[index + 1]
    #expect(type(of: spacer) == NSView.self && spacer.subviews.isEmpty, "后一个是留白")

    let block = try #require(fixture.host.sidebarView.block(for: entry.id))
    #expect(block.titleLabel.stringValue == "list")
    #expect(block.isHidden, "还没有项目")
    block.render(
      ToolBarSegment(id: entry.id, pluginName: "Test", iconPath: nil, content: .items(items(3)), runningSince: nil))
    #expect(!block.isHidden)
    fixture.root.layoutSubtreeIfNeeded()
    #expect(abs(sections.frame.width - column.bounds.width) < 0.5)
    #expect(abs(block.frame.width - column.bounds.width) < 0.5)
    let list = try #require(block.listView)
    #expect(abs(list.frame.height - 3 * InterfaceScale.length(24)) < 0.5)
  }

  @Test("bar 纵向列表：每项一行占满宽度、自上而下排，超过 32 项截断；失败行与授权行的点击与横条一致；脚本按 32 项解析")
  func sidebarBarListsItemsVertically() async throws {
    let list = ToolBarListView()
    list.translatesAutoresizingMaskIntoConstraints = true
    list.frame = NSRect(x: 0, y: 0, width: 220, height: 2_000)
    list.horizontalInset = 10
    var clicked: [String] = []
    var retried: [String] = []
    var approved: [String] = []
    list.onItem = { _, item in clicked.append(item.text ?? "") }
    list.onRetry = { retried.append($0) }
    list.onApprove = { approved.append($0) }
    list.apply(
      segment: ToolBarSegment(id: "s", pluginName: "Test", iconPath: nil, content: .items(items(40)), runningSince: nil))
    list.layoutSubtreeIfNeeded()
    let rowHeight = InterfaceScale.length(24)
    #expect(list.rows.count == ToolBarProtocol.listItemLimit)
    let height = list.constraints.first { $0.firstAttribute == .height && $0.firstItem === list }
    #expect(height?.constant == CGFloat(ToolBarProtocol.listItemLimit) * rowHeight)
    for (index, row) in list.rows.enumerated() {
      #expect(abs(row.frame.minX - 10) < 0.5 && abs(row.frame.width - 200) < 0.5)
      #expect(abs(row.frame.midY - (CGFloat(index) + 0.5) * rowHeight) < 0.5)
    }
    #expect(list.rows[1].accessibilityPerformPress())
    #expect(clicked == ["item 1"])

    list.apply(segment: ToolBarSegment(id: "s", pluginName: "Test", iconPath: nil, content: .failed("boom"), runningSince: nil))
    #expect(list.rows.count == 1)
    #expect(list.rows[0].accessibilityPerformPress())
    #expect(retried == ["s"])
    list.apply(segment: ToolBarSegment(id: "s", pluginName: "Test", iconPath: nil, content: .needsApproval, runningSince: nil))
    #expect(list.rows[0].accessibilityPerformPress())
    #expect(approved == ["s"])
    list.apply(segment: ToolBarSegment(id: "s", pluginName: "Test", iconPath: nil, content: .items([]), runningSince: nil))
    #expect(list.isHidden && height?.constant == 0)

    // 宿主：侧栏 bar 的脚本请求按 32 项解析，结果画进区块；横条视图仍是 12 项。
    let runner = RecordingToolBarRunner()
    runner.handler = { _ in ToolBarOutput(items: [ToolBarItem(text: "a"), ToolBarItem(text: "b")]) }
    let side = makeToolViewEntry(viewID: "list", slot: .sidebarSection)
    let bottom = makeToolViewEntry(viewID: "bottom", slot: .tabBottom)
    let (host, model, _) = makeHost(entries: [side, bottom], runner: runner)
    defer {
      host.teardown()
      withExtendedLifetime(model) {}
    }
    host.setSidebarAvailable(true)
    host.scheduler.isVisible = true
    await pollUntil { runner.requests.count == 2 }
    let limits = Dictionary(uniqueKeysWithValues: runner.requests.map { ($0.viewID, $0.itemLimit) })
    #expect(limits == ["list": ToolBarProtocol.listItemLimit, "bottom": ToolBarProtocol.itemLimit])
    let block = try #require(host.sidebarView.block(for: side.id))
    await pollUntil { block.listView?.rows.count == 2 }
    #expect(block.listView?.rows.map(\.menuTitle) == ["a", "b"])
    #expect(!block.isHidden)
  }

  @Test("panel 区块：高度取清单 height（缺省 240、夹到 80–400）；ui.setHeight 夹到 80–400 后只改约束")
  func sidebarPanelUsesManifestHeightAndClampsSetHeight() async throws {
    let runner = RecordingToolBarRunner()
    let entries = [panelEntry(viewID: "a", height: 120), panelEntry(viewID: "b"), panelEntry(viewID: "c", height: 999)]
    let (host, model, catalog) = makeHost(entries: entries, runner: runner)
    defer {
      host.teardown()
      withExtendedLifetime(model) {}
    }
    host.setSidebarAvailable(true)
    let blocks = try entries.map { try #require(host.sidebarView.block(for: $0.id)) }
    #expect(blocks.map(\.panelHeight) == [120, 240, 400])

    let block = blocks[0]
    let session = try #require(block.mountedSession)
    #expect(session.request.view?.slot == .sidebarSection)
    #expect(session.view.superview === block.panelContainer)
    let sessionHost = try #require(session.host)
    sessionHost.toolSession(session, didRequestHeight: 30)
    #expect(block.panelHeight == 80)
    sessionHost.toolSession(session, didRequestHeight: 300)
    #expect(block.panelHeight == 300)
    sessionHost.toolSession(session, didRequestHeight: 2_000)
    #expect(block.panelHeight == 400)
    #expect(host.sidebarView.block(for: entries[0].id) === block, "改高度不重建区块")

    // 目录刷新（声明没变）：区块与页面要过的高度都保留。
    catalog.send()
    #expect(host.sidebarView.block(for: entries[0].id) === block)
    #expect(block.panelHeight == 400)

    // 桥接：侧栏面板的 ui.setHeight 按 80–400 夹取，Inspector / 普通工具仍按 ui.height 的范围。
    let directory = try makeTemporaryPluginDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var request = makeWebToolRequest()
    request.view = ToolViewPlacement(contribution: entries[0].contribution, slot: .sidebarSection)
    let bridge = ToolBridge(plugin: makeWebToolPlugin(directory: directory), services: FakeToolBridgeServices())
    let delegate = FakeToolBridgeDelegate(request: request)
    bridge.delegate = delegate
    _ = await callBridge(bridge, "ui.setHeight", ["height": 50])
    _ = await callBridge(bridge, "ui.setHeight", ["height": 900])
    #expect(delegate.heights == [80, 400])
  }

  @Test("panel 会话跨整树重建复用：同一区块、同一会话，视图仍挂在侧栏里")
  func sidebarPanelSessionSurvivesRefresh() async throws {
    let entry = panelEntry()
    let fixture = makeFixture(entries: [entry])
    defer { fixture.close() }
    let block = try #require(fixture.host.sidebarView.block(for: entry.id))
    let session = try #require(block.mountedSession)
    let firstColumn = try #require(fixture.host.sidebarView.superview)
    #expect(session.view.isDescendant(of: fixture.root))
    #expect(fixture.host.panelCache.cachedEntryIDs == [entry.id])

    fixture.workspace.scheduleRefresh()
    await pollUntil { fixture.host.sidebarView.superview != nil && fixture.host.sidebarView.superview !== firstColumn }
    #expect(fixture.host.sidebarView.superview !== firstColumn)
    await settleToolBarTasks()
    #expect(fixture.host.sidebarView.block(for: entry.id) === block)
    #expect(block.mountedSession === session)
    #expect(session.view.isDescendant(of: fixture.root))
    #expect(!session.view.subviews.isEmpty, "没有 teardown")
  }

  @Test("顶部标签栏布局：侧栏视图不挂载、不建 feed、不建 panel 会话；改回竖排后挂上，再改走又撤掉")
  func sidebarSectionsAreSkippedInHorizontalTabBarLayout() async throws {
    let bar = makeToolViewEntry(viewID: "list", slot: .sidebarSection)
    let panel = panelEntry()
    let fixture = makeFixture(entries: [bar, panel], layout: .top)
    defer { fixture.close() }
    #expect(find("tool-sidebar-sections", in: fixture.root) == nil)
    #expect(!fixture.host.isSidebarAvailable)
    #expect(fixture.host.sidebarEntries.isEmpty)
    #expect(fixture.host.scheduler.feed(id: bar.id) == nil)
    #expect(fixture.host.panelCache.cachedEntryIDs.isEmpty)

    fixture.preferences.tabBarLayout = .vertical
    fixture.workspace.scheduleRefresh()
    await pollUntil { find("tool-sidebar-sections", in: fixture.root) != nil }
    #expect(fixture.host.scheduler.feed(id: bar.id) != nil)
    #expect(fixture.host.panelCache.cachedEntryIDs == [panel.id])

    fixture.preferences.tabBarLayout = .bottom
    fixture.workspace.scheduleRefresh()
    await pollUntil { find("tool-sidebar-sections", in: fixture.root) == nil }
    #expect(fixture.host.scheduler.feed(id: bar.id) == nil)
    await pollUntil { fixture.host.panelCache.cachedEntryIDs.isEmpty }
    #expect(fixture.host.panelCache.cachedEntryIDs.isEmpty)
  }
}
