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
  /// 临时 host-facts.json 与假采集器：输出由 `probeOutput` 决定，不连任何主机。
  let facts: SSHHostFactsDirectory
  let hosts: [SSHHostProfile]
  /// 假采集器返回的脚本输出。
  nonisolated static let probeOutput = """
    ASTER_HOST_FACTS_V1
    uname_s=Linux
    uname_r=6.8.0
    uname_m=x86_64
    hostname=app
    os_PRETTY_NAME="Ubuntu 24.04 LTS"
    os_ID=ubuntu
    cpu_count=2
    mem_kb=2097152
    end
    """

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsterHostsPage-\(UUID().uuidString)", isDirectory: true)
    let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
    facts = SSHHostFactsDirectory(
      store: SSHHostFactsStore(fileURL: root.appendingPathComponent("host-facts.json")),
      collector: { _ in Self.probeOutput })
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
    model: AppModel(defaults: defaults), directory: fixture.directory, factsDirectory: fixture.facts,
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

  // 卡片副标题沿用 ssh, 用户名；右键菜单给出连接/编辑/复制/添加为机器/删除。
  let card = try #require(page.hostsGrid.items.first as? HostsPageCardView)
  #expect(card.content.subtitle.hasPrefix("ssh, "))
  let menu = page.makeHostMenu(try fixture.host("monite").id)
  #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    == [L("连接"), L("编辑主机…"), L("创建副本"), L("复制 SSH 命令"), L("添加为远程开发机器…"), L("刷新系统信息"), L("删除主机…")])
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

@Test("主机页分组动作：新建空分组出卡片、重命名带着主机走、删除后主机变未分组；导入组不能改名")
@MainActor
func hostsPageGroupActions() throws {
  let fixture = try HostsPageFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let suite = "HostsPage.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let page = HostsPageViewController(
    model: model, directory: fixture.directory, factsDirectory: fixture.facts,
    usageLedger: { HostUsageLedger() }, localUser: "tester")
  page.loadViewIfNeeded()

  // 新建空分组：卡片出现、数量 0，可以钻进去，空状态说明怎么加主机。
  #expect(page.createGroup(" staging "))
  page.reload()
  #expect(page.listing.groups.contains(HostBrowserGroup(name: "staging", hostCount: 0)))
  page.enterGroup("staging")
  #expect(page.query.group == "staging")
  #expect(page.listing.hosts.isEmpty)
  #expect(page.emptyStateText() == L("这个分组还没有主机。点「新建主机」会直接加到这一组；也可以在编辑主机时填这个分组名。"))
  // 重名被拒绝并提示。
  #expect(!page.createGroup("dx-test"))
  #expect(model.notice == L("已经有叫“\("dx-test")”的分组"))

  // 钻在 dx-test 里重命名：主机跟着改，页面留在新名下。
  page.enterGroup("dx-test")
  #expect(page.renameGroup("dx-test", to: "dx"))
  #expect(page.query.group == "dx")
  #expect(page.listing.hosts.map(\.name) == ["app-server", "db-server"])
  #expect(fixture.directory.savedHosts.filter { $0.group == "dx" }.count == 2)
  #expect(!fixture.directory.savedHosts.contains { $0.group == "dx-test" })

  // 删除分组：主机保留并变成未分组，页面回到顶层。
  #expect(page.deleteGroup("dx"))
  page.reload()
  #expect(page.query.group == nil)
  #expect(fixture.directory.savedHosts.filter { $0.group == nil }.count == 7)
  #expect(!page.listing.groups.contains { $0.name == "dx" })

  // 分组菜单：普通分组有重命名与删除，导入组没有。
  #expect(page.makeGroupMenu("客户").items.filter { !$0.isSeparatorItem }.map(\.title)
    == [L("打开"), L("重命名分组…"), L("在此分组新建主机…"), L("删除分组…")])
  #expect(page.makeGroupMenu(SSHHostProfile.importedGroup).items.filter { !$0.isSeparatorItem }.map(\.title)
    == [L("打开"), L("在此分组新建主机…")])
  #expect(page.makeNewHostMenu().items.filter { !$0.isSeparatorItem }.map(\.title).contains(L("新建分组…")))
}

@Test("主机页卡片：主机卡片要双击才连接，分组卡片单击就进")
@MainActor
func hostsPageHostCardsOpenOnDoubleClickOnly() throws {
  let fixture = try HostsPageFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let suite = "HostsPage.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let page = HostsPageViewController(
    model: AppModel(defaults: defaults), directory: fixture.directory, factsDirectory: fixture.facts,
    usageLedger: { HostUsageLedger() }, localUser: "tester")
  page.loadViewIfNeeded()

  let hostCard = try #require(page.hostsGrid.items.first as? HostsPageCardView)
  let groupCard = try #require(page.groupsGrid.items.first as? HostsPageCardView)
  #expect(hostCard.opensOnDoubleClick)
  #expect(!groupCard.opensOnDoubleClick)
  #expect(!HostsPageCardView.shouldOpen(clickCount: 1, doubleClick: true))
  #expect(HostsPageCardView.shouldOpen(clickCount: 2, doubleClick: true))
  #expect(HostsPageCardView.shouldOpen(clickCount: 1, doubleClick: false))
}

@Test("主机页系统信息：采集后卡片按系统换图标、副标题带配置摘要；连接事件只在缺失或过期时采集；删主机后清理")
@MainActor
func hostsPageShowsCollectedSystemFacts() async throws {
  let fixture = try HostsPageFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let suite = "HostsPage.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let page = HostsPageViewController(
    model: model, directory: fixture.directory, factsDirectory: fixture.facts,
    usageLedger: { HostUsageLedger() }, localUser: "tester")
  page.loadViewIfNeeded()
  let host = try fixture.host("monite")

  func card() throws -> HostsPageCardView {
    try #require(
      page.hostsGrid.items.compactMap { $0 as? HostsPageCardView }
        .first { $0.content.identifier == "hosts-page-host-\(host.id.uuidString)" })
  }
  // 还没采集：通用服务器图标，副标题只有 ssh, 用户名；不是远程机器的连接目标，没有标注。
  #expect(try card().content.symbol == "server.rack")
  #expect(try card().content.subtitle == "ssh, root")
  #expect(try card().content.badge == nil)

  // 手动刷新：图标按 Linux，副标题追加摘要，工具提示带详情，提示写到 notice，文件落盘。
  let facts = try await fixture.facts.refresh(hostID: host.id)
  page.reload()
  #expect(facts.family == .linux)
  #expect(try card().content.symbol == "terminal")
  #expect(try card().content.subtitle == "ssh, root · Ubuntu 24.04 LTS · \(L("\("2") 核")) · 2 GB")
  #expect(try card().content.toolTip?.contains("x86_64") == true)
  #expect(SSHHostFactsStore(fileURL: fixture.root.appendingPathComponent("host-facts.json")).load()[host.id] == facts)

  // 连接事件：刚采过（未过期）不再采；换一台没采过的主机会采。
  let other = try fixture.host("deploy-server")
  fixture.facts.handleLinkState(SSHLinkStateEvent(endpoint: "x", hostID: host.id, state: .connected))
  fixture.facts.handleLinkState(SSHLinkStateEvent(endpoint: "y", hostID: other.id, state: .connected))
  fixture.facts.handleLinkState(SSHLinkStateEvent(endpoint: "z", hostID: nil, target: "a@b", state: .connected))
  for _ in 0..<50 where fixture.facts.facts[other.id] == nil {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(fixture.facts.facts[other.id]?.osName == "Ubuntu 24.04 LTS")
  #expect(fixture.facts.facts.count == 2)

  // 删掉主机后它的信息被清理。
  try fixture.directory.remove(other.id)
  for _ in 0..<50 where fixture.facts.facts[other.id] != nil {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(fixture.facts.facts[other.id] == nil)
  #expect(fixture.facts.facts[host.id] == facts)
}

@Test("主机页：被远程开发机器引用的主机带「远程开发机器」标注，工具提示列出机器名")
@MainActor
func hostsPageMarksRemoteMachineHosts() async throws {
  let fixture = try HostsPageFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let suite = "HostsPage.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let host = try fixture.host("deploy-server")
  var services = HostsPageEditorServices.live()
  services.machines = { [MachineProfile(label: "构建机", hostID: host.id)] }
  let model = AppModel(defaults: defaults)
  let page = HostsPageViewController(
    model: model, directory: fixture.directory, factsDirectory: fixture.facts,
    usageLedger: { HostUsageLedger() }, localUser: "tester", editorServices: services)
  page.loadViewIfNeeded()
  let cards = page.hostsGrid.items.compactMap { $0 as? HostsPageCardView }
  let marked = try #require(cards.first { $0.content.identifier == "hosts-page-host-\(host.id.uuidString)" })
  #expect(marked.content.badge == L("远程开发机器"))
  #expect(marked.content.toolTip?.contains("构建机") == true)
  #expect(hostsPageView("hosts-page-host-\(host.id.uuidString)-badge", in: marked) != nil)
  #expect(cards.filter { $0.content.badge != nil }.count == 1)

  // 沿用主机页证据开关，检查较长产品名称在真实窗口中的卡片布局，不抢键盘焦点。
  if let directory = ProcessInfo.processInfo.environment["ASTER_HOSTS_PAGE_EVIDENCE_DIR"] {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    let hub = HostsHubViewController(model: model, hostsPage: page, factories: [:])
    window.appearance = NSAppearance(named: .aqua)
    window.contentViewController = hub
    defer { window.orderOut(nil); window.contentViewController = nil }
    window.orderFront(nil)
    for width in [1000.0, 700.0] {
      window.setContentSize(NSSize(width: width, height: 700))
      window.contentView?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = [
        "-x", "-o", "-l", String(window.windowNumber),
        URL(fileURLWithPath: directory)
          .appendingPathComponent("remote-development-machine-\(Int(width)).png").path,
      ]
      try capture.run()
      capture.waitUntilExit()
      #expect(capture.terminationStatus == 0)
    }
  }
}
