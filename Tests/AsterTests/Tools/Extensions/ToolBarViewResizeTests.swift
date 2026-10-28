// 原生 bar 拖高：拖边缘按整行拉高并换行、夹在单行与上限之间、双击复位、多行超出时上下滚动、
// 高度按窗口 suite 按位置记住、window.top 不可拖高。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
extension ToolBarViewTests {
  /// 把条挂进一个容器（贴左右与底边），条高由它自己的高度约束决定。
  private func mount(_ bar: ToolBarView, width: CGFloat) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    container.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    container.layoutSubtreeIfNeeded()
    return container
  }

  /// 合成一个窗口坐标下的鼠标事件。
  private func mouse(_ type: NSEvent.EventType, y: CGFloat, clicks: Int = 1) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: 10, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
  }

  /// 按下把手、拖到 `toY`、（可选）松开。
  private func drag(_ handle: ToolBarResizeHandle, from fromY: CGFloat, to toY: CGFloat, release: Bool = true) throws {
    handle.mouseDown(with: try mouse(.leftMouseDown, y: fromY))
    handle.mouseDragged(with: try mouse(.leftMouseDragged, y: toY))
    if release { handle.mouseUp(with: try mouse(.leftMouseUp, y: toY)) }
  }

  private func items(_ count: Int) -> [ToolBarItem] {
    (0..<count).map { ToolBarItem(text: "item \($0)") }
  }

  @Test("拖 tab.bottom 条的上边缘往上：按整行拉高，项目换行排成多行；松开才回调高度")
  func dragTopEdgeGrowsBottomBarAndWrapsItems() throws {
    let bar = ToolBarView(slot: .tabBottom, height: 26)
    let container = mount(bar, width: 300)
    var commits: [Double] = []
    bar.onHeightCommit = { commits.append($0) }
    bar.apply(segments: [segment(items: items(4)), segment("q/view:other", items: items(6))])
    container.layoutSubtreeIfNeeded()
    let handle = try #require(bar.resizeHandle)
    #expect(handle.edge == .top)
    #expect(abs(handle.frame.maxY - bar.bounds.maxY) < 0.5 && handle.frame.height == 4)

    // 往上 60pt：26 + 60 = 86，吸附成 3 行。
    try drag(handle, from: 10, to: 70, release: false)
    #expect(handle.isHighlighted)
    container.layoutSubtreeIfNeeded()
    #expect(bar.rows == 3)
    #expect(abs(bar.frame.height - InterfaceScale.length(26) * 3) < 0.5)
    #expect(commits.isEmpty, "拖动中不持久化")
    handle.mouseUp(with: try mouse(.leftMouseUp, y: 70))
    #expect(!handle.isHighlighted)
    #expect(commits == [78])

    let rows = Set(bar.visibleButtons.map(\.frame.minY))
    #expect(rows.count > 1, "放不下一行时换行")
    #expect(bar.visibleButtons.count == 10)
    #expect(bar.visibleButtons.allSatisfy { $0.frame.maxX <= 300 - InterfaceScale.length(8) + 0.5 })
    // 顺序与脚本输出一致：按行从上到下、行内从左到右。
    let order = bar.visibleButtons.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    #expect(order.map(\.menuTitle) == (0..<4).map { "item \($0)" } + (0..<6).map { "item \($0)" })
  }

  @Test("拖动夹在单行与 8 行之间；tab.top 拖下边缘，往下变高")
  func dragIsClampedBetweenOneRowAndMaximum() throws {
    let bar = ToolBarView(slot: .tabBottom, height: 26)
    let container = mount(bar, width: 300)
    bar.apply(segments: [segment(items: items(3))])
    let handle = try #require(bar.resizeHandle)
    try drag(handle, from: 0, to: 10_000)
    container.layoutSubtreeIfNeeded()
    #expect(bar.rows == ToolBarHeightPolicy.maximumRows)
    #expect(abs(bar.frame.height - InterfaceScale.length(26) * 8) < 0.5)
    try drag(handle, from: 0, to: -10_000)
    container.layoutSubtreeIfNeeded()
    #expect(bar.rows == 1)
    #expect(abs(bar.frame.height - InterfaceScale.length(26)) < 0.5)
    // 不到半行不跳。
    try drag(handle, from: 0, to: 12)
    #expect(bar.rows == 1)

    let top = ToolBarView(slot: .tabTop, height: 26)
    _ = mount(top, width: 300)
    let topHandle = try #require(top.resizeHandle)
    #expect(topHandle.edge == .bottom)
    try drag(topHandle, from: 100, to: 100 - 52)
    #expect(top.rows == 3)
    try drag(topHandle, from: 100, to: 10_000)
    #expect(top.rows == 1)
  }

  @Test("双击边缘恢复单行并持久化")
  func doubleClickEdgeResetsToSingleRow() throws {
    let bar = ToolBarView(slot: .windowBottom, height: 26)
    let container = mount(bar, width: 300)
    var commits: [Double] = []
    bar.onHeightCommit = { commits.append($0) }
    bar.apply(segments: [segment(items: items(3))])
    bar.restoreHeight(78)
    container.layoutSubtreeIfNeeded()
    #expect(bar.rows == 3)
    #expect(commits.isEmpty, "套用记住的高度不回写")
    let handle = try #require(bar.resizeHandle)
    handle.mouseDown(with: try mouse(.leftMouseDown, y: 5, clicks: 1))
    handle.mouseUp(with: try mouse(.leftMouseUp, y: 5, clicks: 1))
    #expect(commits.isEmpty, "单击不改高度")
    handle.mouseDown(with: try mouse(.leftMouseDown, y: 5, clicks: 2))
    handle.mouseUp(with: try mouse(.leftMouseUp, y: 5, clicks: 2))
    container.layoutSubtreeIfNeeded()
    #expect(bar.rows == 1)
    #expect(abs(bar.frame.height - InterfaceScale.length(26)) < 0.5)
    #expect(commits == [26])
  }

  @Test("拉高后内容超出可见行数时上下滚动，滚轮不再转成横向")
  func multiRowOverflowScrollsVertically() throws {
    let bar = ToolBarView(slot: .paneBottom, height: 24)
    let container = mount(bar, width: 200)
    bar.restoreHeight(48)
    bar.apply(segments: [segment(items: items(20))])
    container.layoutSubtreeIfNeeded()
    #expect(bar.rows == 2)
    let scroll = bar.scrollView
    #expect(!scroll.convertsVerticalWheel)
    #expect(scroll.canScrollVertically)
    #expect(!scroll.canScrollHorizontally, "多行时按宽度换行，不横向溢出")
    let lineCount = Set(bar.visibleButtons.map(\.frame.minY)).count
    #expect(lineCount > 2)
    let document = try #require(scroll.documentView)
    #expect(abs(document.frame.height - CGFloat(lineCount) * InterfaceScale.length(24)) < 0.5)

    // 滚到底，最后一项可见；内容变少后滚动位置收回。
    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    let last = try #require(bar.visibleButtons.last)
    #expect(scroll.contentView.bounds.contains(NSPoint(x: last.frame.midX, y: last.frame.midY)))
    bar.apply(segments: [segment(items: items(2))])
    container.layoutSubtreeIfNeeded()
    #expect(!scroll.canScrollVertically)
    #expect(scroll.contentView.bounds.origin.y == 0)
  }

  @Test("高度按窗口 suite 按位置记住；坏数据回退默认，越界值夹到上限；宿主建条时套用并在提交时写回")
  func heightPersistsPerSlotInWindowSuite() throws {
    func suite(_ name: String) -> UserDefaults {
      let suite = "ToolBarViewResizeTests.\(name).\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defaults.removePersistentDomain(forName: suite)
      return defaults
    }
    let first = suite("first")
    let second = suite("second")
    let store = ToolBarHeightStore(defaults: first)
    store.setHeight(78, for: .tabBottom)
    store.setHeight(48, for: .paneBottom)
    store.setHeight(56, for: .windowTop)
    let restored = ToolBarHeightStore(defaults: first)
    #expect(restored.height(for: .tabBottom) == 78)
    #expect(restored.height(for: .paneBottom) == 48)
    #expect(restored.height(for: .windowTop) == nil, "不可拖高的位置不记")
    #expect(ToolBarHeightStore(defaults: second).height(for: .tabBottom) == nil, "另一个窗口互不影响")

    second.set(Data("not-json".utf8), forKey: ToolBarHeightStore.persistenceKey)
    #expect(ToolBarHeightStore(defaults: second).heights == ToolBarHeights())
    let bar = ToolBarView(slot: .tabBottom, height: 26)
    bar.restoreHeight(10_000)
    #expect(bar.rows == ToolBarHeightPolicy.maximumRows)

    // 宿主：建条时套用本窗口 suite 里的值，拖高松开后写回。
    let model = AppModel(defaults: first)
    let preferences = AppPreferences(defaults: first)
    let catalog = FakeToolViewCatalog()
    catalog.viewEntries = [makeToolViewEntry(slot: .tabBottom), makeToolViewEntry(viewID: "top", slot: .tabTop)]
    let host = WorkspaceExtensionHost(
      model: model, preferences: preferences, catalog: catalog, runner: { _ in ToolBarOutput(items: []) })
    defer { host.teardown() }
    let bottom = try #require(host.existingBar(for: .tabBottom))
    #expect(bottom.rows == 3)
    let top = try #require(host.existingBar(for: .tabTop))
    #expect(top.rows == 1)
    try drag(try #require(top.resizeHandle), from: 100, to: 100 - 26)
    #expect(top.rows == 2)
    #expect(ToolBarHeightStore(defaults: first).height(for: .tabTop) == 52)
    #expect(ToolBarHeightStore(defaults: first).height(for: .tabBottom) == 78)
  }

  @Test("window.top 固定单行：没有拖高把手，记住的高度也不生效")
  func windowTopBarIsNotResizable() {
    let bar = ToolBarView(slot: .windowTop, height: 28)
    #expect(bar.resizeHandle == nil)
    bar.restoreHeight(200)
    #expect(bar.rows == 1)
    bar.apply(segments: [segment(items: items(2))])
    let height = bar.constraints.first { $0.firstAttribute == .height && $0.firstItem === bar }
    #expect(height?.constant == 28)
    #expect(!ToolBarHeightPolicy.isResizable(.windowTop))
    #expect(!ToolBarHeightPolicy.isResizable(.sidebarSection))
  }
}
