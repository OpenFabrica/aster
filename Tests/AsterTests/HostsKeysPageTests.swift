// 「主机 → 密钥」原生子页：卡片与徽标、搜索、横幅、详情面板与右键菜单。动作流程见
// HostsKeysPageActionsTests.swift。设置 `ASTER_HOSTS_KEYS_EVIDENCE_DIR` 时截下真实窗口供人工核对。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 页面夹具：服务夹具 + 假对话框 + 外壳窗口（标题带里的分段控件与真实页面一致）。
@MainActor
struct KeysPageFixture {
  let vault: VaultActionsFixture
  let fakePrompts = FakeKeysPrompts()
  let page: HostsKeysViewController
  let window: NSWindow
  let defaultsSuite = "HostsKeysPage.\(UUID().uuidString)"

  init(
    hosts: [SSHHostProfile] = [], tool: FakeVaultKeyTool = FakeVaultKeyTool(), engine: SSHEngine = .native,
    appearance: NSAppearance.Name = .aqua, size: NSSize = NSSize(width: 1_180, height: 720)
  ) throws {
    vault = try VaultActionsFixture(hosts: hosts, tool: tool, engine: engine)
    let recorder = vault.recorder
    page = HostsKeysViewController(
      actions: vault.actions, prompts: fakePrompts.prompts,
      notify: { recorder.toasts.append(($0, $1)) })
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    let model = AppModel(defaults: defaults)
    let page = page
    let hub = HostsHubViewController(
      model: model, hostsPage: HostsPageViewController(model: model, directory: vault.hosts),
      factories: [.keys: { page }])
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = AsterTheme.paper
    window.contentViewController = hub
    window.setContentSize(size)
    hub.select(.keys)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  func cleanUp() {
    window.orderOut(nil)
    UserDefaults().removePersistentDomain(forName: defaultsSuite)
    vault.cleanUp()
  }

  /// 刷新并布局（目录变化经主队列合并，测试里直接重算）。
  func settle() {
    page.reload()
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 卡片视图。
  var cards: [HostsKeyCardView] { page.grid.items.compactMap { $0 as? HostsKeyCardView } }
}

/// 按 identifier 递归找视图。
@MainActor
private func keysPageView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  return root.subviews.lazy.compactMap { keysPageView(identifier, in: $0) }.first
}

/// 设置了 `ASTER_HOSTS_KEYS_EVIDENCE_DIR` 时截下窗口，文件名 `aster-keys-<name>-<light|dark>.png`。
@MainActor
private func captureKeysPage(_ window: NSWindow, name: String) async throws {
  guard let directory = ProcessInfo.processInfo.environment["ASTER_HOSTS_KEYS_EVIDENCE_DIR"] else { return }
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(300))
  let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
    URL(fileURLWithPath: directory).appendingPathComponent("aster-keys-\(name)-\(appearance).png").path]
  try capture.run()
  capture.waitUntilExit()
  #expect(capture.terminationStatus == 0)
}

/// 填一组演示密钥：导入的（原文件仍在、可迁移）、被主机使用的、钥匙串缺失的。
@MainActor
private func seedDemoKeys(_ fixture: KeysPageFixture) async throws -> [SSHVaultKey] {
  let vault = fixture.vault
  let original = try vault.writeFile(".ssh/id_ed25519", "PLAIN")
  let laptop = try await vault.addKey("Xk3vQ9pLm2RtY7wZbN4cJ8", label: "MacBook Pro", importedFrom: original.path)
  let deploy = try await vault.addKey("Fh2Lq8sTn5VyR1mKpW6dG3", label: "deploy-ci")
  let legacy = try await vault.addKey("Pz7Jc4gUw9XbE2nHsQ5tA1", label: "legacy-rsa")
  for name in ["app-server", "db-server"] {
    try vault.hosts.upsert(SSHHostProfile(name: name, host: "\(name).internal", vaultKeyIDs: [deploy.id]))
  }
  try vault.credentials.deleteVaultPrivateKey(id: legacy.id)
  await vault.keys.refreshKeychainPresence().value
  return [laptop, deploy, legacy]
}

@Test("密钥页：卡片带类型、短指纹与徽标；搜索过滤；选中打开详情；菜单与网页版一致",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func hostsKeysPageRendersCardsAndDetail(appearance: NSAppearance.Name) async throws {
  let jump = SSHHostProfile(name: "jump", host: "jump.example.com", identityFiles: ["~/.ssh/id_ed25519"])
  let fixture = try KeysPageFixture(hosts: [jump], appearance: appearance)
  defer { fixture.cleanUp() }
  let root = try #require(fixture.window.contentView)

  // 空状态。
  #expect(fixture.page.emptyStateText() == L("还没有保险库密钥。导入 ~/.ssh 里的私钥，或生成一把新的 Ed25519 密钥。"))
  #expect(keysPageView("hosts-keys-engine-banner", in: root) == nil)
  try await captureKeysPage(fixture.window, name: "empty")

  let keys = try await seedDemoKeys(fixture)
  fixture.settle()
  #expect(fixture.cards.map(\.row.key.label) == ["deploy-ci", "legacy-rsa", "MacBook Pro"])
  #expect(fixture.page.emptyStateText() == nil)
  let deployCard = try #require(fixture.cards.first)
  #expect(deployCard.row.usedBy == ["app-server", "db-server"])
  let badgeTexts = { (card: HostsKeyCardView) in
    card.subviews.flatMap { hostsKeyBadges(in: $0) }.map(\.text)
  }
  #expect(badgeTexts(deployCard) == [L("\(String(2)) 台主机使用")])
  #expect(badgeTexts(fixture.cards[1]) == [L("钥匙串中缺失")])
  #expect(badgeTexts(fixture.cards[2]) == [L("原文件仍在")])
  try await captureKeysPage(fixture.window, name: "list")

  // 选中导入的密钥：详情面板列出迁移与删除原文件；菜单项与网页版顺序一致。
  fixture.page.select(keys[0].id)
  fixture.window.contentView?.layoutSubtreeIfNeeded()
  #expect(!fixture.page.detailView.isHidden)
  #expect(fixture.page.detailView.row?.migratableHosts == ["jump"])
  #expect(fixture.page.detailView.actionButtons.compactMap(\.identifier?.rawValue) == [
    "hosts-keys-detail-copy", "hosts-keys-detail-rename", "hosts-keys-detail-migrate",
    "hosts-keys-detail-delete-original", "hosts-keys-detail-delete",
  ])
  let menu = fixture.page.makeKeyMenu(keys[0].id)
  #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
    L("复制公钥"), L("重命名…"), L("改用保险库密钥（\(String(1)) 台主机）…"), L("删除原文件…"), L("删除…"),
  ])
  #expect(fixture.page.makeKeyMenu(keys[1].id).items.filter { !$0.isSeparatorItem }.map(\.title) == [
    L("复制公钥"), L("重命名…"), L("删除…"),
  ])
  try await captureKeysPage(fixture.window, name: "detail")

  // 缺失私钥的密钥详情。
  fixture.page.select(keys[2].id)
  fixture.window.contentView?.layoutSubtreeIfNeeded()
  try await captureKeysPage(fixture.window, name: "detail-missing")

  // 搜索：主机名命中被它使用的密钥；没有匹配时提示。
  fixture.page.searchField.stringValue = "db-server"
  fixture.page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(fixture.page.visibleRows.map(\.id) == [keys[1].id])
  fixture.page.searchField.stringValue = "nothing-matches"
  fixture.page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  #expect(fixture.page.emptyStateText() == L("没有匹配的密钥。"))

  // 外部删除选中的密钥后面板收起。
  try await fixture.vault.keys.remove(keys[2].id)
  fixture.settle()
  #expect(fixture.page.selectedID == nil)
  #expect(fixture.page.detailView.isHidden)
}

/// 递归找出徽标。
@MainActor
private func hostsKeyBadges(in root: NSView) -> [HostsKeyBadgeView] {
  ((root as? HostsKeyBadgeView).map { [$0] } ?? []) + root.subviews.flatMap { hostsKeyBadges(in: $0) }
}

@Test("密钥页：OpenSSH 引擎与 ssh-keys.json 读取失败时显示横幅", arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func hostsKeysPageShowsBanners(appearance: NSAppearance.Name) async throws {
  let fixture = try KeysPageFixture(engine: .openssh, appearance: appearance)
  defer { fixture.cleanUp() }
  _ = try await seedDemoKeys(fixture)
  try Data("{broken".utf8).write(to: fixture.vault.keys.store.fileURL)
  fixture.vault.keys.reload()
  fixture.settle()
  let root = try #require(fixture.window.contentView)
  #expect(keysPageView("hosts-keys-engine-banner", in: root) != nil)
  #expect(keysPageView("hosts-keys-error-banner", in: root) != nil)
  // 读取失败时保留最后一次有效列表。
  #expect(fixture.cards.count == 3)
  try await captureKeysPage(fixture.window, name: "banners")
}
