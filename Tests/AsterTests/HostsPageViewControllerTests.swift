// 侧栏「主机」页：卡片渲染、搜索/钻取/列表切换、侧栏入口位置与回到终端的路径。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 主机页测试用的临时 hosts.json 与演示主机；不读写用户真实配置。
@MainActor
private struct HostsPageFixture {
  let root: URL
  let directory: SSHHostDirectory
  let hosts: [SSHHostProfile]

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsterHostsPage-\(UUID().uuidString)", isDirectory: true)
    let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
    hosts = [
      SSHHostProfile(name: "app-server", group: "dx-test", host: "172.16.10.146", user: "dx"),
      SSHHostProfile(name: "db-server", group: "dx-test", host: "172.16.10.198", user: "duoxieyun"),
      SSHHostProfile(name: "jumpserver", group: "公司阿里云", host: "47.1.2.3", user: "ops"),
      SSHHostProfile(name: "客户网关", group: "客户", host: "10.8.0.1", user: "root"),
      SSHHostProfile(name: "10.160.71.40", host: "10.160.71.40", user: "root"),
      SSHHostProfile(name: "deploy-server", host: "deploy.example.com", user: "duoxieyun", tags: ["prod"]),
      SSHHostProfile(name: "local ollama server", host: "192.168.1.20", user: "mike"),
      SSHHostProfile(name: "lanmac mini", host: "lanmac.local", user: "mikelan", tags: ["home"]),
      SSHHostProfile(name: "monite", host: "monite.internal", port: 2222, user: "root"),
    ]
    try store.save([.emptyDefaults()] + hosts)
    directory = SSHHostDirectory(store: store)
  }

  /// 按名称取主机。
  func host(_ name: String) throws -> SSHHostProfile {
    try #require(hosts.first { $0.name == name })
  }
}

/// 递归找出某类视图。
@MainActor
private func hostsPageViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
  ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { hostsPageViews(type, in: $0) }
}

/// 按 identifier 递归找视图。
@MainActor
private func hostsPageView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for subview in root.subviews {
    if let found = hostsPageView(identifier, in: subview) { return found }
  }
  return nil
}

/// 设置了 `ASTER_HOSTS_PAGE_EVIDENCE_DIR` 时截下测试窗口，供人工核对视觉效果。
@MainActor
private func captureHostsPageWindow(_ window: NSWindow, name: String) async throws {
  guard let directory = ProcessInfo.processInfo.environment["ASTER_HOSTS_PAGE_EVIDENCE_DIR"] else { return }
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(300))
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ? "dark" : "light"
  capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
    URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(appearance).png").path]
  try capture.run()
  capture.waitUntilExit()
  #expect(capture.terminationStatus == 0)
}

@Test("卡片网格列数随宽度变化：宽窗 3 列、窄窗递减，列表模式恒为 1 列")
@MainActor
func hostsPageGridColumns() {
  #expect(HostsPageGridView.columns(forWidth: 1_000, listMode: false) == 3)
  #expect(HostsPageGridView.columns(forWidth: 500, listMode: false) == 2)
  #expect(HostsPageGridView.columns(forWidth: 200, listMode: false) == 1)
  #expect(HostsPageGridView.columns(forWidth: 3_000, listMode: false) == 3)
  #expect(HostsPageGridView.columns(forWidth: 1_000, listMode: true) == 1)
}

@Test("主机页：分组与未分组主机成卡片，搜索平铺匹配主机，钻进分组后有面包屑")
@MainActor
func hostsPageRendersFiltersAndDrillsIntoGroups() throws {
  let fixture = try HostsPageFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let suite = "HostsPage.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let page = HostsPageViewController(
    model: AppModel(defaults: defaults), directory: fixture.directory,
    usageLedger: { HostUsageLedger() }, localUser: "tester")
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.contentViewController = page
  // contentViewController 会把窗口缩到视图的初始尺寸，这里显式还原成宽窗。
  window.setContentSize(NSSize(width: 1_000, height: 700))
  defer { window.orderOut(nil) }
  window.contentView?.layoutSubtreeIfNeeded()

  // 中文分组的先后随系统语言区域变化，这里只核对集合。
  #expect(Set(page.listing.groups.map(\.name)) == ["dx-test", "公司阿里云", "客户"])
  #expect(page.groupsGrid.items.count == 3)
  #expect(page.hostsGrid.items.count == 5)
  // 宽 1000 的页面放得下 3 列：第一行三张卡片同一 y，第四张换行。
  let frames = page.hostsGrid.items.map(\.frame)
  #expect(frames[0].minY == frames[2].minY && frames[3].minY > frames[0].minY)
  let breadcrumb = try #require(hostsPageView("hosts-page-breadcrumb", in: page.view))
  #expect(breadcrumb.isHidden)

  // 搜索用户名：主机区平铺分组内外的匹配主机；两台都匹配时回车无法决定，连接按钮不可用。
  page.searchField.stringValue = "duoxieyun"
  page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(page.listing.groups.isEmpty)
  #expect(page.listing.hosts.map(\.name) == ["db-server", "deploy-server"])
  #expect(!page.connectButton.isEnabled)
  // 输入地址：可临时连接。
  page.searchField.stringValue = "root@203.0.113.9:2200"
  page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(page.connectButton.isEnabled)

  // 清空后钻进分组：只看这一组，出现面包屑；分组被删空后自动回到顶层。
  page.searchField.stringValue = ""
  page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  page.enterGroup("dx-test")
  #expect(page.listing.hosts.map(\.name) == ["app-server", "db-server"])
  #expect(!breadcrumb.isHidden)
  for name in ["app-server", "db-server"] { try fixture.directory.remove(try fixture.host(name).id) }
  page.reload()
  #expect(page.query.group == nil)
  #expect(Set(page.listing.groups.map(\.name)) == ["公司阿里云", "客户"])

  // 卡片副标题沿用 ssh, 用户名；右键菜单给出连接/编辑/复制/删除。
  let card = try #require(page.hostsGrid.items.first as? HostsPageCardView)
  #expect(card.content.subtitle.hasPrefix("ssh, "))
  let menu = page.makeHostMenu(try fixture.host("monite").id)
  #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    == [L("连接"), L("编辑主机…"), L("创建副本"), L("复制 SSH 命令"), L("删除主机…")])
}

@Test("侧栏「主机」在「工作区」上方；点开后内容区换成主机页，选中标签即回到终端",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func hostsPageSidebarEntryPresentsAndDismisses(appearance: NSAppearance.Name) async throws {
  let fixture = try HostsPageFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let suite = "HostsPageSidebar.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .vertical
  preferences.appearance = appearance == .darkAqua ? .dark : .light
  preferences.setCompatibilityValue(.string("/bin/sh"), forKey: "general.shell")
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let controller = WorkspaceViewController(
    model: model, preferences: preferences, hostsDirectory: fixture.directory)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_240, height: 780),
    styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.appearance = NSAppearance(named: appearance)
  window.titlebarAppearsTransparent = true
  window.titleVisibility = .hidden
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()

  let root = try #require(window.contentView)
  let row = try #require(hostsPageView("workspace-sidebar-hosts-row", in: root))
  let groupTitle = try #require(hostsPageView("workspace-group-section-title", in: root))
  let rowFrame = row.convert(row.bounds, to: nil)
  let titleFrame = groupTitle.convert(groupTitle.bounds, to: nil)
  // 窗口坐标原点在左下：「主机」行在「工作区」标题之上。
  #expect(rowFrame.minY > titleFrame.maxY)
  let count = try #require(hostsPageView("workspace-sidebar-hosts-count", in: root) as? NSTextField)
  #expect(count.stringValue == "9")

  model.presentHostsPage()
  try await Task.sleep(for: .milliseconds(150))
  root.layoutSubtreeIfNeeded()
  #expect(hostsPageView("hosts-page", in: root) != nil)
  #expect(hostsPageViews(HostsPageCardView.self, in: root).count == 3 + 5)
  #expect(window.firstResponder === (hostsPageView("hosts-page-search-field", in: root) as? NSTextField)?
    .currentEditor())
  try await captureHostsPageWindow(window, name: "hosts-page")
  let hub = try #require(controller.children.compactMap { $0 as? HostsHubViewController }.first)
  let page = hub.hostsPage
  if ProcessInfo.processInfo.environment["ASTER_HOSTS_PAGE_EVIDENCE_DIR"] != nil {
    // 取证：钻进分组、列表模式、输入快连地址、窄窗口。
    page.enterGroup("dx-test")
    try await captureHostsPageWindow(window, name: "hosts-page-group")
    page.leaveGroup()
    page.toggleLayoutMode()
    try await captureHostsPageWindow(window, name: "hosts-page-list")
    page.toggleLayoutMode()
    page.searchField.stringValue = "root@203.0.113.9:2200"
    page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    try await captureHostsPageWindow(window, name: "hosts-page-search")
    page.searchField.stringValue = ""
    page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    window.setContentSize(NSSize(width: 860, height: 640))
    try await captureHostsPageWindow(window, name: "hosts-page-narrow")
  }

  // 再选一次当前标签：主机页关闭，终端回来。
  model.select(tab)
  try await Task.sleep(for: .milliseconds(150))
  #expect(!model.isHostsPagePresented)
  #expect(hostsPageView("hosts-page", in: root) == nil)
}
