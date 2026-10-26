// 已知主机的大列表：通过外壳切换子页，检查渲染行数有界及分页交互。
import AppKit
import AsterCore
import Testing

@testable import Aster

/// 大量合成记录；不读取或改写用户的 known_hosts。
func paginatedKnownHostsListing(count: Int) -> SSHKnownHostsListing {
  let path = "/tmp/aster-known-hosts-pagination/known_hosts"
  return SSHKnownHostsListing(
    files: [.init(path: path, exists: true, writable: true, global: false)],
    entries: (1...max(count, 1)).prefix(count).map { line in
      .init(file: path, line: line, hosts: ["host-\(line).example.com"], algorithm: "ssh-ed25519",
        fingerprint: "SHA256:pagination-\(line)", lineDigest: "digest-\(line)")
    })
}

@Test("已知主机：从顶部切换到大列表页面时只创建一页记录视图", arguments: [250, 1_000])
@MainActor
func knownHostsPageLargeListRemainsBounded(count: Int) async throws {
  let fake = KnownHostsServiceFakeTool()
  await fake.setListings([paginatedKnownHostsListing(count: count)])
  let service = SSHKnownHostsService(dependencies: fake.dependencies, hosts: { [] }, machineTargets: { [] })
  let page = KnownHostsPageViewController(service: service)
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let defaults = try #require(UserDefaults(suiteName: "KnownHostsPagination.\(UUID().uuidString)"))
  let model = AppModel(defaults: defaults)
  let hosts = HostsPageViewController(model: model, directory: fixture.directory, editorServices: fixture.services)
  let hub = HostsHubViewController(model: model, hostsPage: hosts, factories: [.knownHosts: { page }])
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = hub
  window.setContentSize(NSSize(width: 960, height: 720))
  defer { window.orderOut(nil) }
  let clock = ContinuousClock()
  let start = clock.now
  hub.segmentedControl.selectedSegment = try #require(HostsHubSection.allCases.firstIndex(of: .knownHosts))
  hub.segmentedControl.performClick(nil)
  await knownHostsWait { service.state == .loaded }
  window.contentView?.layoutSubtreeIfNeeded()
  print("KnownHosts large-list: \(start.duration(to: clock.now)), rows=\(page.rowViews.count)")
  #expect(service.state == .loaded)
  #expect(!page.rowViews.isEmpty && page.rowViews.count <= 50)
  try await captureKnownHostsWindow(window, name: "hub-tabs-large-\(count)")
}

/// 分页交互用的页面与原生窗口；服务只访问内存替身。
@MainActor
private struct KnownHostsPaginationFixture {
  let fake: KnownHostsServiceFakeTool
  let service: SSHKnownHostsService
  let page: KnownHostsPageViewController
  let window: NSWindow

  init(count: Int, appearance: NSAppearance.Name) async {
    fake = KnownHostsServiceFakeTool()
    await fake.setListings([paginatedKnownHostsListing(count: count)])
    service = SSHKnownHostsService(dependencies: fake.dependencies, hosts: { [] }, machineTargets: { [] })
    page = KnownHostsPageViewController(service: service)
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentViewController = page
    window.setContentSize(NSSize(width: 960, height: 720))
    page.pageDidAppear()
    await knownHostsWait { service.state == .loaded }
    window.contentView?.layoutSubtreeIfNeeded()
  }

  func button(_ identifier: String) throws -> NSButton {
    func find(_ view: NSView) -> NSButton? {
      if view.identifier?.rawValue == identifier { return view as? NSButton }
      return view.subviews.lazy.compactMap(find).first
    }
    return try #require(find(page.view))
  }

  func search(_ text: String) {
    page.searchField.stringValue = text
    page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  }
}

@Test("已知主机分页：按钮翻页、搜索全部记录、Esc 清空回首页，末页删除后返回有效页",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func knownHostsPagePaginationActions(appearance: NSAppearance.Name) async throws {
  let fixture = await KnownHostsPaginationFixture(count: 101, appearance: appearance)
  defer { fixture.window.orderOut(nil) }
  let page = fixture.page
  let previous = try fixture.button("known-hosts-previous-page")
  let next = try fixture.button("known-hosts-next-page")
  #expect(page.pageIndex == 0 && page.pageCount == 3)
  #expect(!previous.isEnabled && next.isEnabled)
  #expect(page.rowViews.map(\.row.entry.line) == Array(1...50))
  #expect(page.rowViews[0].visibleRect.height > 0)
  try await captureKnownHostsWindow(fixture.window, name: "pagination-first")
  let bottomRow = try #require(page.rowViews.last)
  bottomRow.scrollToVisible(bottomRow.bounds)
  let clip = try #require(bottomRow.enclosingScrollView?.contentView)
  #expect(clip.bounds.minY > 0)
  next.performClick(nil)
  #expect(clip.bounds.minY == 0)
  #expect(page.rowViews.map(\.row.entry.line) == Array(51...100))
  #expect(previous.isEnabled && next.isEnabled)
  next.performClick(nil)
  #expect(page.pageIndex == 2 && page.rowViews.map(\.row.entry.line) == [101])
  #expect(page.rowViews[0].visibleRect.height > 0)
  #expect(!next.isEnabled)
  try await captureKnownHostsWindow(fixture.window, name: "pagination-last")

  // 搜索的是其它页里的记录，清空后回到完整结果第一页。
  fixture.search("host-75.example.com")
  #expect(page.pageIndex == 0 && page.pageCount == 1)
  #expect(page.rowViews.map(\.row.entry.line) == [75])
  _ = page.control(page.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
  #expect(page.pageIndex == 0 && page.rowViews.count == 50)
  fixture.search("no-such-host")
  #expect(page.pageIndex == 0 && page.pageCount == 1 && page.rowViews.isEmpty)
  fixture.search("")
  next.performClick(nil)
  previous.performClick(nil)
  #expect(page.pageIndex == 0)
  next.performClick(nil)
  next.performClick(nil)
  let last = try #require(page.rowViews.first?.row.entry)
  await fixture.fake.setListings([paginatedKnownHostsListing(count: 100)])
  page.remove(last, choice: .line)
  await knownHostsWait { fixture.service.state == .loaded && !fixture.service.isRemoving && page.pageCount == 2 }
  #expect(page.pageIndex == 1 && page.rowViews.map(\.row.entry.line) == Array(51...100))
  #expect(await fixture.fake.removeRequests.first?.line == 101)
  #expect(await fixture.fake.removeRequests.first?.lineDigest == "digest-101")

  fixture.window.setContentSize(NSSize(width: 700, height: 540))
  fixture.window.contentView?.layoutSubtreeIfNeeded()
  let bar = try #require(next.superview?.superview)
  #expect(bar.convert(bar.bounds, to: page.view).maxY <= page.view.bounds.maxY)
  #expect(previous.convert(previous.bounds, to: page.view).minX >= 0)
  #expect(next.convert(next.bounds, to: page.view).maxX <= page.view.bounds.maxX)
  try await captureKnownHostsWindow(fixture.window, name: "pagination-narrow")

  // 加载失败时保留当前页和可用的翻页操作。
  await fixture.fake.setListError(SSHBrokerError.executableMissing)
  fixture.service.refresh()
  await knownHostsWait { fixture.service.state != .loading }
  #expect(page.pageIndex == 1 && page.rowViews.count == 50)
  #expect(previous.isEnabled && !next.isEnabled)
  try await captureKnownHostsWindow(fixture.window, name: "pagination-error")
}
