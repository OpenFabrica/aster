// 界面扩展挂到真实工作区：tab.bottom 条跨整树重建是同一实例、贴在 Pane 区下面；tab.top 条成为 contentHeader；
// 停用视图后条被撤下；详情面板拿到窗口的插件面板提供方；pane.bottom 每个终端 Pane 一条、用该 Pane 自己的目录；
// activePane.bottom 只有一条，跟着焦点在终端 Pane 之间搬动。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：挂到工作区")
struct WorkspaceExtensionMountTests {
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

  /// `layout` 给了就按它恢复一个标签（多 Pane 用），否则用默认的单终端标签。
  private func makeFixture(entries: [ToolViewEntry], layout: PaneLayout? = nil) throws -> Fixture {
    let suite = "WorkspaceExtensionMountTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    if let layout {
      let tab = WorkspaceTabSnapshot(id: UUID(), title: "Panes", layout: layout)
      defaults.set(
        try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
        forKey: "aster.workspace.snapshot.v1")
    }
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
    return Fixture(window: window, workspace: workspace, catalog: catalog)
  }

  /// 视图树里挂在 `slot` 的条。
  private func mountedBar(_ slot: ToolViewSlot, in root: NSView) -> ToolBarView? {
    if let bar = root as? ToolBarView, bar.slot == slot { return bar }
    for subview in root.subviews {
      if let bar = mountedBar(slot, in: subview) { return bar }
    }
    return nil
  }

  /// 让条显示一项，便于按几何位置断言。
  private func show(_ bar: ToolBarView?, id: String) {
    bar?.apply(segments: [
      ToolBarSegment(id: id, pluginName: "Test", iconPath: nil, content: .items([ToolBarItem(text: "main")]),
        runningSince: nil)
    ])
  }

  @Test("tab.bottom 条跨整树重建是同一实例，贴在 Pane 区下面、与内容区同宽")
  func tabBottomBarIsSameInstanceAcrossRefresh() async throws {
    let entry = makeToolViewEntry(slot: .tabBottom)
    let fixture = try makeFixture(entries: [entry])
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let bar = try #require(mountedBar(.tabBottom, in: root))
    #expect(bar === fixture.host.existingBar(for: .tabBottom))
    let firstParent = try #require(bar.superview as? NSStackView)
    #expect(firstParent.arrangedSubviews.last === bar)

    fixture.workspace.scheduleRefresh()
    await pollUntil { bar.superview != nil && bar.superview !== firstParent }
    #expect(bar.superview !== firstParent)
    #expect(mountedBar(.tabBottom, in: root) === bar)

    show(bar, id: entry.id)
    root.layoutSubtreeIfNeeded()
    let center = try #require(bar.superview as? NSStackView)
    let index = try #require(center.arrangedSubviews.firstIndex { $0 === bar })
    let paneHost = center.arrangedSubviews[index - 1]
    #expect(abs(bar.frame.height - InterfaceScale.length(26)) < 0.5)
    #expect(abs(paneHost.frame.minY - bar.frame.maxY) < 0.5)
    #expect(abs(bar.frame.minY - center.bounds.minY) < 0.5)
    #expect(abs(bar.frame.width - center.bounds.width) < 0.5)
  }

  @Test("tab.top 条插在标题与查找条之后，成为 contentHeader：Pane 区从它的底边开始")
  func tabTopBarBecomesContentHeader() throws {
    let entry = makeToolViewEntry(slot: .tabTop)
    let fixture = try makeFixture(entries: [entry])
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let bar = try #require(mountedBar(.tabTop, in: root))
    #expect(mountedBar(.tabBottom, in: root) == nil)
    let center = try #require(bar.superview as? NSStackView)
    let index = try #require(center.arrangedSubviews.firstIndex { $0 === bar })
    let paneHost = center.arrangedSubviews[index + 1]
    #expect(
      center.constraints.contains {
        $0.firstItem === paneHost && $0.firstAttribute == .top && $0.secondItem === bar
          && $0.secondAttribute == .bottom
      })
    show(bar, id: entry.id)
    root.layoutSubtreeIfNeeded()
    #expect(abs(paneHost.frame.maxY - bar.frame.minY) < 0.5)
  }

  @Test("停用视图后条从工作区撤下；重新启用后挂回同一实例")
  func disablingViewUnmountsBar() async throws {
    let entry = makeToolViewEntry(slot: .tabBottom)
    let fixture = try makeFixture(entries: [entry])
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let bar = try #require(mountedBar(.tabBottom, in: root))

    fixture.catalog.viewEntries = [makeToolViewEntry(slot: .tabBottom, isEnabled: false)]
    fixture.catalog.send()
    #expect(fixture.host.bar(for: .tabBottom) == nil)
    await pollUntil { mountedBar(.tabBottom, in: root) == nil }
    #expect(mountedBar(.tabBottom, in: root) == nil)
    #expect(fixture.host.barEntries.isEmpty)

    fixture.catalog.viewEntries = [entry]
    fixture.catalog.send()
    await pollUntil { mountedBar(.tabBottom, in: root) != nil }
    #expect(mountedBar(.tabBottom, in: root) === bar)
  }

  @Test("详情面板拿到窗口的插件面板提供方；只列 inspector.panel 的可挂载面板")
  func detailsPanelReceivesPluginPanelProvider() throws {
    let panel = makeToolViewEntry(viewID: "status", kind: .panel, slot: .inspectorPanel)
    let disabled = makeToolViewEntry(viewID: "off", kind: .panel, slot: .inspectorPanel, isEnabled: false)
    let fixture = try makeFixture(entries: [panel, disabled, makeToolViewEntry(slot: .tabBottom)])
    defer { fixture.close() }
    #expect(fixture.host.inspectorPanelEntries.map(\.id) == [panel.id])
    let details = fixture.workspace.detailsControllerForSelectedTab()
    #expect(details.pluginPanels === fixture.host)
  }

  /// 视图树里某个 Pane 的宿主。
  private func paneHost(_ paneID: UUID, in root: NSView) -> ActivePaneHostView? {
    if let host = root as? ActivePaneHostView, host.paneID == paneID { return host }
    for subview in root.subviews {
      if let host = paneHost(paneID, in: subview) { return host }
    }
    return nil
  }

  /// 两个终端 Pane（不同目录）加一个文件 Pane。
  private func makePaneLayout() throws -> (PaneLayout, PaneDescriptor, PaneDescriptor, PaneDescriptor) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-pane-bar-\(UUID().uuidString)", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let a = PaneDescriptor(kind: .terminal, workingDirectory: first.path)
    let b = PaneDescriptor(kind: .terminal, workingDirectory: second.path)
    let files = PaneDescriptor(kind: .fileBrowser, workingDirectory: root.path)
    let layout = PaneLayout.split(
      axis: .horizontal, first: .leaf(a),
      second: .split(axis: .vertical, first: .leaf(b), second: .leaf(files), ratio: 0.5), ratio: 0.5)
    return (layout, a, b, files)
  }

  @Test("pane.bottom：每个终端 Pane 一条（文件 Pane 不挂），跨整树重建是同一实例；停用后撤下")
  func paneBottomBarMountsPerTerminalPaneAndSurvivesRefresh() async throws {
    let entry = makeToolViewEntry(slot: .paneBottom)
    let (layout, a, b, files) = try makePaneLayout()
    let fixture = try makeFixture(entries: [entry], layout: layout)
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let hostA = try #require(paneHost(a.id, in: root))
    let barA = try #require(fixture.host.existingPaneBar(for: a.id))
    let barB = try #require(fixture.host.existingPaneBar(for: b.id))
    #expect(barA !== barB)
    #expect(hostA.installedExtensionBar === barA)
    #expect(paneHost(b.id, in: root)?.installedExtensionBar === barB)
    #expect(paneHost(files.id, in: root)?.installedExtensionBar == nil)
    #expect(fixture.host.existingPaneBar(for: files.id) == nil)
    #expect(mountedBar(.tabBottom, in: root) == nil)

    fixture.workspace.scheduleRefresh()
    await pollUntil { paneHost(a.id, in: root).map { $0 !== hostA } ?? false }
    let newHostA = try #require(paneHost(a.id, in: root))
    #expect(newHostA !== hostA)
    #expect(newHostA.installedExtensionBar === barA)
    #expect(fixture.host.existingPaneBar(for: a.id) === barA)

    fixture.catalog.viewEntries = [makeToolViewEntry(slot: .paneBottom, isEnabled: false)]
    fixture.catalog.send()
    #expect(fixture.host.existingPaneBar(for: a.id) == nil)
    await pollUntil { paneHost(a.id, in: root)?.installedExtensionBar == nil }
    #expect(paneHost(a.id, in: root)?.installedExtensionBar == nil)
    #expect(barA.superview == nil)
  }

  @Test("pane.bottom 的上下文取该 Pane 自己的目录与 Pane id，不是活动 Pane")
  func paneBottomUsesEachPanesOwnWorkingDirectory() throws {
    let entry = makeToolViewEntry(slot: .paneBottom, triggers: [.cwd, .activePane])
    let (layout, a, b, _) = try makePaneLayout()
    let fixture = try makeFixture(entries: [entry], layout: layout)
    defer { fixture.close() }
    let contextA = try #require(fixture.host.paneContext(for: a.id))
    let contextB = try #require(fixture.host.paneContext(for: b.id))
    #expect(contextA.workingDirectory == a.workingDirectory)
    #expect(contextB.workingDirectory == b.workingDirectory)
    #expect(contextA.paneID == a.id.uuidString)
    #expect(contextB.paneID == b.id.uuidString)
    #expect(!contextB.isRemote)
    let keyB = ToolBarScheduler.paneFeedKey(entryID: entry.id, paneID: b.id)
    #expect(fixture.host.scheduler.feed(id: keyB)?.context.workingDirectory == b.workingDirectory)
  }

  @Test("tab.bottom 跟随活动 Pane：切到另一个 Pane 后上下文换成它的目录与 Pane id")
  func tabBottomFollowsActivePaneSwitch() throws {
    let entry = makeToolViewEntry(slot: .tabBottom, triggers: [.cwd, .activePane])
    let (layout, a, b, _) = try makePaneLayout()
    let fixture = try makeFixture(entries: [entry], layout: layout)
    defer { fixture.close() }
    let tab = try #require(fixture.workspace.model.selectedTab)
    tab.setActivePane(a.id)
    #expect(fixture.host.scheduler.feed(id: entry.id)?.context.workingDirectory == a.workingDirectory)
    tab.setActivePane(b.id)
    #expect(fixture.host.scheduler.feed(id: entry.id)?.context.paneID == b.id.uuidString)
    #expect(fixture.host.scheduler.feed(id: entry.id)?.context.workingDirectory == b.workingDirectory)
  }

  // MARK: - activePane.bottom

  @Test("activePane.bottom：只挂在活动终端 Pane 底部，贴底、与 Pane 同宽；整树重建后挂到新宿主")
  func activePaneBarMountsUnderFocusedTerminalPane() async throws {
    let entry = makeToolViewEntry(slot: .activePaneBottom)
    let (layout, a, b, files) = try makePaneLayout()
    let fixture = try makeFixture(entries: [entry], layout: layout)
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let tab = try #require(fixture.workspace.model.selectedTab)
    tab.setActivePane(a.id)
    let bar = try #require(fixture.host.existingBar(for: .activePaneBottom))
    let hostA = try #require(paneHost(a.id, in: root))
    #expect(hostA.installedActivePaneBar === bar)
    #expect(paneHost(b.id, in: root)?.installedActivePaneBar == nil)
    #expect(paneHost(files.id, in: root)?.installedActivePaneBar == nil)
    #expect(mountedBar(.tabBottom, in: root) == nil)

    show(bar, id: entry.id)
    root.layoutSubtreeIfNeeded()
    #expect(abs(bar.frame.height - InterfaceScale.length(24)) < 0.5)
    #expect(abs(bar.frame.minY - hostA.bounds.minY) < 0.5)
    #expect(abs(bar.frame.width - hostA.bounds.width) < 0.5)

    fixture.workspace.scheduleRefresh()
    await pollUntil { paneHost(a.id, in: root).map { $0 !== hostA } ?? false }
    let newHostA = try #require(paneHost(a.id, in: root))
    #expect(newHostA !== hostA)
    #expect(newHostA.installedActivePaneBar === bar)
    #expect(fixture.host.existingBar(for: .activePaneBottom) === bar)
  }

  @Test("activePane.bottom：焦点换 Pane 时同一条搬到新 Pane 下面，不整树重建，上下文换成新 Pane")
  func activePaneBarMovesWithFocusWithoutRebuild() async throws {
    let entry = makeToolViewEntry(slot: .activePaneBottom, triggers: [.cwd, .activePane])
    let (layout, a, b, _) = try makePaneLayout()
    let fixture = try makeFixture(entries: [entry], layout: layout)
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let tab = try #require(fixture.workspace.model.selectedTab)
    tab.setActivePane(a.id)
    // 先排空装窗时排下的整树刷新，之后宿主实例变化才只可能来自焦点切换。
    await pollUntil(timeout: .milliseconds(150)) { false }
    let bar = try #require(fixture.host.existingBar(for: .activePaneBottom))
    let hostA = try #require(paneHost(a.id, in: root))
    let hostB = try #require(paneHost(b.id, in: root))
    #expect(hostA.installedActivePaneBar === bar)

    tab.setActivePane(b.id)
    #expect(hostB.installedActivePaneBar === bar)
    #expect(hostA.installedActivePaneBar == nil)
    #expect(fixture.host.scheduler.feed(id: entry.id)?.context.workingDirectory == b.workingDirectory)
    // 等过几轮主队列：若焦点切换排了整树重建，Pane 宿主会被换成新实例。
    await pollUntil(timeout: .milliseconds(150)) { false }
    #expect(paneHost(a.id, in: root) === hostA)
    #expect(paneHost(b.id, in: root) === hostB)
    #expect(hostB.installedActivePaneBar === bar)
    #expect(fixture.host.existingBar(for: .activePaneBottom) === bar)

    tab.setActivePane(a.id)
    #expect(hostA.installedActivePaneBar === bar)
    #expect(hostB.installedActivePaneBar == nil)
  }

  @Test("activePane.bottom：活动 Pane 不是终端（文件 Pane）时条不挂，回到终端 Pane 再挂上")
  func activePaneBarSkipsNonTerminalPane() throws {
    let entry = makeToolViewEntry(slot: .activePaneBottom)
    let (layout, a, b, files) = try makePaneLayout()
    let fixture = try makeFixture(entries: [entry], layout: layout)
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let tab = try #require(fixture.workspace.model.selectedTab)
    tab.setActivePane(a.id)
    let bar = try #require(fixture.host.existingBar(for: .activePaneBottom))

    tab.setActivePane(files.id)
    #expect(bar.superview == nil)
    for paneID in [a.id, b.id, files.id] {
      #expect(paneHost(paneID, in: root)?.installedActivePaneBar == nil)
    }

    tab.setActivePane(b.id)
    #expect(paneHost(b.id, in: root)?.installedActivePaneBar === bar)
  }

  @Test("activePane.bottom 与 pane.bottom 同时启用：活动 Pane 底部两条都在，pane.bottom 在上")
  func activePaneBarCoexistsWithPaneBottomBar() throws {
    let paneEntry = makeToolViewEntry(viewID: "pane", slot: .paneBottom)
    let activeEntry = makeToolViewEntry(viewID: "active", slot: .activePaneBottom)
    let (layout, a, b, _) = try makePaneLayout()
    let fixture = try makeFixture(entries: [paneEntry, activeEntry], layout: layout)
    defer { fixture.close() }
    let root = try #require(fixture.window.contentView)
    let tab = try #require(fixture.workspace.model.selectedTab)
    tab.setActivePane(a.id)
    let hostA = try #require(paneHost(a.id, in: root))
    let paneBar = try #require(fixture.host.existingPaneBar(for: a.id))
    let activeBar = try #require(fixture.host.existingBar(for: .activePaneBottom))
    #expect(hostA.installedExtensionBar === paneBar)
    #expect(hostA.installedActivePaneBar === activeBar)
    #expect(paneHost(b.id, in: root)?.installedExtensionBar != nil)
    #expect(paneHost(b.id, in: root)?.installedActivePaneBar == nil)

    show(paneBar, id: ToolBarScheduler.paneFeedKey(entryID: paneEntry.id, paneID: a.id))
    show(activeBar, id: activeEntry.id)
    root.layoutSubtreeIfNeeded()
    // 非翻转坐标：pane.bottom 条的下边贴着活动 Pane 条的上边，活动 Pane 条贴 Pane 底。
    #expect(abs(paneBar.frame.minY - activeBar.frame.maxY) < 0.5)
    #expect(abs(activeBar.frame.minY - hostA.bounds.minY) < 0.5)
  }

  @Test("窗口没上屏时不跑脚本：调度器保持不可见")
  func offscreenWindowKeepsSchedulerPaused() throws {
    let fixture = try makeFixture(entries: [makeToolViewEntry(slot: .tabBottom)])
    defer { fixture.close() }
    #expect(!fixture.host.scheduler.isVisible)
    #expect(fixture.host.scheduler.runningCount == 0)
  }
}
