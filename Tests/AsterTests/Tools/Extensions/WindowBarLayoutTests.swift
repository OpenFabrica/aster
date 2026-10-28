// 插件 window.top / window.bottom 条挂到真实工作区：全宽、window.bottom 在底部标签栏下面、window.top 让开红绿灯并
// 接管红绿灯行（侧栏不再预留、顶部标签栏不再建标题带）；没有条时布局与原来一样；条跨整树重建是同一实例。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：window.top / window.bottom 布局")
struct WindowBarLayoutTests {
  /// 标签栏的几种摆法；`nil` 表示隐藏标签栏。
  private static let layouts: [TabBarLayout?] = [.vertical, .top, .bottom, nil]

  /// 装进窗口的工作区。
  @MainActor
  private struct Fixture {
    let window: NSWindow
    let workspace: WorkspaceViewController
    let catalog: FakeToolViewCatalog

    var host: WorkspaceExtensionHost { workspace.extensionHost }
    var root: NSView { workspace.view }

    /// 关窗并停掉扩展宿主。
    func close() {
      workspace.extensionHost.teardown()
      window.close()
    }

    /// 根视图里第一个带 `identifier` 的视图。
    func view(_ identifier: String) -> NSView? { Self.find(identifier, in: root) }

    /// 在根视图坐标里的 frame。
    func frame(of view: NSView) -> NSRect { view.convert(view.bounds, to: root) }

    private static func find(_ identifier: String, in view: NSView) -> NSView? {
      if view.identifier?.rawValue == identifier { return view }
      for subview in view.subviews {
        if let found = find(identifier, in: subview) { return found }
      }
      return nil
    }
  }

  private func makeFixture(layout: TabBarLayout?, entries: [ToolViewEntry]) -> Fixture {
    let suite = "WindowBarLayoutTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let model = AppModel(defaults: defaults)
    let preferences = AppPreferences(defaults: defaults)
    preferences.tabBarLayout = layout ?? .vertical
    preferences.configuration.appearance.showTabBar = layout != nil
    preferences.configuration.appearance.autoHideTabs = false
    model.ensureInitialTab()
    let catalog = FakeToolViewCatalog()
    catalog.viewEntries = entries
    let workspace = WorkspaceViewController(model: model, preferences: preferences, toolViewCatalog: catalog)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = workspace
    window.contentView?.layoutSubtreeIfNeeded()
    return Fixture(window: window, workspace: workspace, catalog: catalog)
  }

  /// 让条显示一项（window.bottom 没有项目时高度为 0）。
  private func show(_ bar: ToolBarView?, _ fixture: Fixture) {
    bar?.apply(segments: [
      ToolBarSegment(id: "p/view:bar", pluginName: "P", iconPath: nil, content: .items([ToolBarItem(text: "main")]),
        runningSince: nil)
    ])
    fixture.root.layoutSubtreeIfNeeded()
  }

  private let topEntry = makeToolViewEntry(viewID: "top", slot: .windowTop)
  private let bottomEntry = makeToolViewEntry(viewID: "bottom", slot: .windowBottom)

  @Test("window.bottom 在每种标签栏布局（含隐藏）里都全宽贴窗口底边")
  func windowBottomBarSpansFullWidthInEveryTabBarLayout() throws {
    for layout in Self.layouts {
      let fixture = makeFixture(layout: layout, entries: [bottomEntry])
      defer { fixture.close() }
      let bar = try #require(fixture.host.existingBar(for: .windowBottom))
      #expect(bar.window === fixture.window, "layout \(String(describing: layout))")
      show(bar, fixture)
      let frame = fixture.frame(of: bar)
      #expect(abs(frame.minX) < 0.5)
      #expect(abs(frame.width - fixture.root.bounds.width) < 0.5)
      #expect(abs(frame.minY) < 0.5)
      #expect(abs(frame.height - InterfaceScale.length(26)) < 0.5)
    }
  }

  @Test("底部标签布局：window.bottom 在标签栏下面（窗口最底）")
  func windowBottomSitsBelowBottomTabBar() throws {
    let fixture = makeFixture(layout: .bottom, entries: [bottomEntry])
    defer { fixture.close() }
    let bar = try #require(fixture.host.existingBar(for: .windowBottom))
    show(bar, fixture)
    let tabBar = try #require(fixture.view("workspace-tabbar"))
    #expect(abs(fixture.frame(of: tabBar).minY - fixture.frame(of: bar).maxY) < 0.5)
  }

  @Test("window.top 固定 28 贴窗口顶边，没有项目也不收起；左内边距让开红绿灯")
  func windowTopBarLeavesTrafficLightInset() throws {
    let fixture = makeFixture(layout: .vertical, entries: [topEntry])
    defer { fixture.close() }
    let bar = try #require(fixture.host.existingBar(for: .windowTop))
    #expect(!bar.isHidden)
    let frame = fixture.frame(of: bar)
    #expect(abs(frame.maxY - fixture.root.bounds.height) < 0.5)
    #expect(abs(frame.height - WindowTopBarMetrics.height) < 0.5)
    #expect(abs(frame.width - fixture.root.bounds.width) < 0.5)
    #expect(bar.isWindowDragRegion)

    let zoom = try #require(fixture.window.standardWindowButton(.zoomButton))
    let zoomFrame = try #require(zoom.superview).convert(zoom.frame, to: nil)
    #expect(bar.leadingInset == ceil(zoomFrame.maxX) + 12)
    #expect(WorkspaceViewController.windowTopBarLeadingInset(for: nil) == 78)
  }

  @Test("垂直标签栏：有 window.top 时侧栏不再预留红绿灯行，只留放悬停按钮的一小条")
  func verticalSidebarDropsTitleBarRowWhenWindowTopBarPresent() throws {
    let plain = makeFixture(layout: .vertical, entries: [])
    defer { plain.close() }
    let withTop = makeFixture(layout: .vertical, entries: [topEntry])
    defer { withTop.close() }
    let plainSidebar = try #require(plain.view("workspace-sidebar"))
    let topSidebar = try #require(withTop.view("workspace-sidebar"))
    let plainHosts = try #require(plainSidebar.firstDescendant(of: HostsSidebarRowView.self))
    let topHosts = try #require(topSidebar.firstDescendant(of: HostsSidebarRowView.self))
    // 没有条：主机行在红绿灯行（30 + 8）下面；有条：侧栏从条底开始，主机行只在 28pt 的按钮条下面。
    #expect(abs(plain.frame(of: plainSidebar).maxY - plain.root.bounds.height) < 0.5)
    #expect(abs(plain.frame(of: plainHosts).maxY - (plain.root.bounds.height - 30 - InterfaceScale.length(8))) < 0.5)
    #expect(abs(withTop.frame(of: topSidebar).maxY - (withTop.root.bounds.height - WindowTopBarMetrics.height)) < 0.5)
    #expect(abs(withTop.frame(of: topHosts).maxY - (withTop.root.bounds.height - WindowTopBarMetrics.height - 28)) < 0.5)
  }

  @Test("顶部标签布局：有 window.top 时标签栏不建标题带，路径胶囊回到内容区标题行")
  func topTabBarMovesTitleIntoContentHeaderWhenWindowTopBarPresent() throws {
    let plain = makeFixture(layout: .top, entries: [])
    defer { plain.close() }
    let plainTabBar = try #require(plain.view("workspace-tabbar"))
    let plainTitle = try #require(plain.view("workspace-titlebar"))
    #expect(plainTitle.isDescendant(of: plainTabBar))

    let withTop = makeFixture(layout: .top, entries: [topEntry])
    defer { withTop.close() }
    let tabBar = try #require(withTop.view("workspace-tabbar"))
    let title = try #require(withTop.view("workspace-titlebar"))
    #expect(!title.isDescendant(of: tabBar))
    #expect(abs(withTop.frame(of: tabBar).height - (withTop.frame(of: plainTabBar).height - 28)) < 0.5)
    #expect(abs(withTop.frame(of: tabBar).maxY - (withTop.root.bounds.height - WindowTopBarMetrics.height)) < 0.5)
    #expect(withTop.frame(of: title).maxY < withTop.frame(of: tabBar).minY + 0.5)
    // 详情面板按钮跟着标题行走，不压在 window.top 条上。
    let toggle = try #require(withTop.view("workspace-inspector-toggle"))
    #expect(abs(withTop.frame(of: toggle).midY - withTop.frame(of: title).midY) < 0.5)
  }

  @Test("没有 window 条（或视图被关掉）时布局与原来一样：顶层直接是 split，红绿灯行与标题带照旧")
  func noWindowBarsKeepsLayoutUnchanged() throws {
    let disabled = [
      makeToolViewEntry(viewID: "top", slot: .windowTop, isEnabled: false),
      makeToolViewEntry(viewID: "bottom", slot: .windowBottom, isEnabled: false),
    ]
    for layout in Self.layouts {
      let fixture = makeFixture(layout: layout, entries: disabled)
      defer { fixture.close() }
      #expect(fixture.host.existingBar(for: .windowTop) == nil)
      #expect(fixture.view("workspace-window-bar-background") == nil)
      let top = try #require(fixture.root.subviews.first { $0 is WorkspacePanelSplitView || $0 is NSStackView })
      #expect(top is WorkspacePanelSplitView, "layout \(String(describing: layout))")
      #expect(abs(fixture.frame(of: top).maxY - fixture.root.bounds.height) < 0.5)
      #expect(abs(fixture.frame(of: top).minY) < 0.5)
      let toggle = try #require(fixture.view("workspace-inspector-toggle"))
      #expect(abs(fixture.frame(of: toggle).midY - (fixture.root.bounds.height - InspectorToggleMetrics.centerYFromTop)) < 0.5)
      if layout == .top {
        let title = try #require(fixture.view("workspace-titlebar"))
        #expect(title.isDescendant(of: try #require(fixture.view("workspace-tabbar"))))
      }
    }
  }

  @Test("window 条跨整树重建是同一实例，仍挂在窗口里")
  func windowBarsAreSameInstanceAcrossRefresh() async throws {
    let fixture = makeFixture(layout: .vertical, entries: [topEntry, bottomEntry])
    defer { fixture.close() }
    let top = try #require(fixture.host.existingBar(for: .windowTop))
    let bottom = try #require(fixture.host.existingBar(for: .windowBottom))
    let firstTopParent = top.superview
    fixture.workspace.scheduleRefresh()
    await pollUntil { top.superview != nil && top.superview !== firstTopParent }
    #expect(top.superview !== firstTopParent)
    #expect(fixture.host.existingBar(for: .windowTop) === top)
    #expect(fixture.host.existingBar(for: .windowBottom) === bottom)
    #expect(top.window === fixture.window)
    #expect(bottom.window === fixture.window)

    // 停用 window.top：条撤下，侧栏恢复红绿灯行。
    fixture.catalog.viewEntries = [bottomEntry]
    fixture.catalog.send()
    await pollUntil { top.window == nil }
    #expect(top.window == nil)
    #expect(bottom.window === fixture.window)
  }
}

extension NSView {
  /// 深度优先找第一个某类型的后代（测试用）。
  fileprivate func firstDescendant<T: NSView>(of type: T.Type) -> T? {
    for subview in subviews {
      if let match = subview as? T { return match }
      if let match = subview.firstDescendant(of: type) { return match }
    }
    return nil
  }
}
