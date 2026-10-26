// 侧栏「主机 → 已知主机」原生子页：分组与徽章、hashed 记录的主机名、搜索、删除确认与选项、错误状态。
// 设置 `ASTER_KNOWN_HOSTS_EVIDENCE_DIR` 时截下浅色 / 深色窗口，供人工核对视觉效果。
import AppKit
import AsterCore
import Testing

@testable import Aster

/// 页面与内容测试共用的列表：可写默认文件（多主机行、hashed、非 22 端口、吊销、CA、跳过行）、
/// 不存在的 OrbStack 文件与只读系统文件。路径放在家目录下，验证 `~` 缩写；文件本身不会被读写。
func knownHostsPageListing() -> SSHKnownHostsListing {
  let user = NSHomeDirectory() + "/.ssh/known_hosts"
  let orb = NSHomeDirectory() + "/.orbstack/ssh/known_hosts"
  return SSHKnownHostsListing(
    files: [
      .init(path: user, exists: true, writable: true, global: false),
      .init(path: orb, exists: false, writable: false, global: false),
      .init(path: "/etc/ssh/ssh_known_hosts", exists: true, writable: false, global: true),
    ],
    entries: [
      .init(
        file: user, line: 1, hosts: ["github.com"], algorithm: "ssh-ed25519",
        fingerprint: "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU", lineDigest: "a1"),
      .init(
        file: user, line: 2, hosts: ["(hashed)"], hashed: true, algorithm: "ecdsa-sha2-nistp256",
        fingerprint: "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
        matches: [SSHHostPort(host: "172.16.10.146", port: 22)], lineDigest: "a2"),
      .init(
        file: user, line: 3, hosts: ["web.example.com", "10.0.0.5"], algorithm: "ssh-ed25519",
        fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s", comment: "deploy key",
        matches: [SSHHostPort(host: "web.example.com", port: 22), SSHHostPort(host: "10.0.0.5", port: 22)],
        lineDigest: "a3"),
      .init(
        file: user, line: 5, hosts: ["[monite.internal]:2222"], algorithm: "rsa-sha2-512",
        fingerprint: "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8",
        matches: [SSHHostPort(host: "monite.internal", port: 2222)], lineDigest: "a5"),
      .init(
        file: user, line: 6, marker: "revoked", hosts: ["old.example.com"], algorithm: "ssh-rsa",
        fingerprint: "SHA256:Zw4dsZ0vYvT0Hi0p0ZVqHnQWQ9QAyeYBFh0P5AQ1xg0", lineDigest: "a6"),
      .init(
        file: "/etc/ssh/ssh_known_hosts", line: 1, marker: "certAuthority", hosts: ["*.corp.example.com"],
        algorithm: "ssh-ed25519", fingerprint: "SHA256:8u0b0aJ3eKJ2N0r4l3yqzqzN1mU3JcY9oG1x6s0aKcQ",
        lineDigest: "g1"),
    ],
    skipped: [.init(file: user, line: 4, reason: "malformed")])
}

/// 页面夹具：假的 aster-ssh、带两台已保存主机的服务、记录提示的页面与窗口。
@MainActor
private final class KnownHostsPageFixture {
  let fake = KnownHostsServiceFakeTool()
  let service: SSHKnownHostsService
  let page: KnownHostsPageViewController
  let window: NSWindow
  var notices: [(text: String, isError: Bool)] = []

  init(appearance: NSAppearance.Name = .aqua, listing: SSHKnownHostsListing? = knownHostsPageListing()) async {
    if let listing { await fake.setListings([listing]) }
    let hosts = [
      SSHHostProfile(name: "app-server", host: "172.16.10.146", user: "dx"),
      SSHHostProfile(name: "monite", host: "monite.internal", port: 2222, user: "root"),
    ]
    service = SSHKnownHostsService(
      dependencies: fake.dependencies, hosts: { [.emptyDefaults()] + hosts }, machineTargets: { [] })
    var record: ((String, Bool) -> Void)?
    page = KnownHostsPageViewController(service: service) { record?($0, $1) }
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentViewController = page
    window.setContentSize(NSSize(width: 960, height: 720))
    record = { [unowned self] in self.notices.append(($0, $1)) }
  }

  /// 首次显示并等到列表加载完成。
  func appearAndLoad() async {
    page.pageDidAppear()
    await knownHostsWait { service.state != .loading && service.state != .idle }
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 输入搜索词。
  func search(_ text: String) {
    page.searchField.stringValue = text
    page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 按行号取记录行。
  func row(_ line: Int) throws -> KnownHostsEntryRowView {
    try #require(page.rowViews.first { $0.row.entry.line == line })
  }
}

/// 设置了 `ASTER_KNOWN_HOSTS_EVIDENCE_DIR` 时按窗口号截下窗口，文件名 `aster-knownhosts-<name>-<外观>.png`。
/// 按窗口号截图不受屏幕上其它窗口遮挡；sheet 是独立窗口，单独传入它的窗口。
@MainActor
func captureKnownHostsWindow(_ window: NSWindow, name: String, appearanceOf owner: NSWindow? = nil) async throws {
  guard let directory = ProcessInfo.processInfo.environment["ASTER_KNOWN_HOSTS_EVIDENCE_DIR"] else { return }
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  window.orderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(450))
  let reference = owner ?? window
  let appearance = reference.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  capture.arguments = [
    "-x", "-o", "-l", String(window.windowNumber),
    URL(fileURLWithPath: directory).appendingPathComponent("aster-knownhosts-\(name)-\(appearance).png").path,
  ]
  try capture.run()
  capture.waitUntilExit()
  #expect(capture.terminationStatus == 0)
}

@Test("已知主机页：首次显示自动列出；按文件分组；只有可写文件的记录有删除按钮；搜索与 Esc 清空",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func knownHostsPageRendersAndFilters(appearance: NSAppearance.Name) async throws {
  let fixture = await KnownHostsPageFixture(appearance: appearance)
  defer { fixture.window.orderOut(nil) }
  #expect(fixture.page.reloadButton.title == L("正在读取…"))
  await fixture.appearAndLoad()
  #expect(await fixture.fake.listCount == 1)
  #expect(fixture.page.reloadButton.isEnabled)

  let sections = fixture.page.sections
  #expect(sections.map(\.displayPath) == ["~/.ssh/known_hosts", "~/.orbstack/ssh/known_hosts", "/etc/ssh/ssh_known_hosts"])
  #expect(sections.map(\.total) == [5, 0, 1])
  #expect(sections[0].skippedLines == [4])
  #expect(fixture.page.rowViews.count == 6)
  #expect(try fixture.row(2).row.title.contains("app-server（172.16.10.146）"))
  #expect(try fixture.row(3).deleteButton != nil)
  #expect(fixture.page.rowViews.filter { $0.row.entry.file == "/etc/ssh/ssh_known_hosts" }.allSatisfy { $0.deleteButton == nil })
  try await captureKnownHostsWindow(fixture.window, name: "populated")

  fixture.search("monite")
  #expect(fixture.page.rowViews.map(\.row.entry.line) == [5])
  #expect(fixture.page.sections[2].placeholder == L("没有匹配“\("monite")”的记录"))
  fixture.search("no-such-host")
  try await captureKnownHostsWindow(fixture.window, name: "no-match")
  let editor = fixture.page.searchField.currentEditor() as? NSTextView ?? NSTextView()
  #expect(
    fixture.page.control(
      fixture.page.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
  #expect(fixture.page.searchField.stringValue.isEmpty)
  #expect(fixture.page.rowViews.count == 6)

  // 已加载过后再次显示不再自动列出（工作区重建会反复回调 pageDidAppear）。
  fixture.page.pageDidAppear()
  #expect(await fixture.fake.listCount == 1)
}

@Test("已知主机页：多主机行的确认框可只删其中一台；删除后提示并重新列出；stale 时提示错误",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func knownHostsPageDeleteFlow(appearance: NSAppearance.Name) async throws {
  let fixture = await KnownHostsPageFixture(appearance: appearance)
  defer { fixture.window.orderOut(nil) }
  await fixture.appearAndLoad()
  let multi = try fixture.row(3).row
  let (alert, choices) = fixture.page.makeDeleteAlert(for: multi)
  #expect(alert.buttons.map(\.title) == [L("删除整行"), L("只删除 \("web.example.com")"), L("只删除 \("10.0.0.5")"), L("取消")])
  #expect(alert.buttons[0].hasDestructiveAction)
  #expect(choices.last == .some(nil))
  #expect(alert.informativeText.contains("~/.ssh/known_hosts · " + L("第 \("3") 行")))
  let single = try fixture.row(1).row
  #expect(fixture.page.makeDeleteAlert(for: single).0.buttons.map(\.title) == [L("删除"), L("取消")])

  // 真实弹出 sheet 供截图，然后按「取消」关闭，不发出删除。
  fixture.window.makeKeyAndOrderFront(nil)
  let sheet = try #require(fixture.page.confirmRemove(multi))
  try await captureKnownHostsWindow(sheet.window, name: "delete-confirm", appearanceOf: fixture.window)
  fixture.window.endSheet(sheet.window, returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3))
  try await Task.sleep(for: .milliseconds(50))
  #expect(await fixture.fake.removeRequests.isEmpty)

  fixture.page.remove(multi.entry, choice: .host(SSHHostPort(host: "10.0.0.5", port: 22)))
  await knownHostsWait { fixture.notices.count == 1 && fixture.service.state == .loaded }
  #expect(
    await fixture.fake.removeRequests == [
      .init(
        file: multi.entry.file, line: 3, lineDigest: "a3", host: SSHHostPort(host: "10.0.0.5", port: 22))
    ])
  #expect(fixture.notices.first?.isError == false)
  #expect(await fixture.fake.listCount == 2)

  await fixture.fake.setRemoveError(SSHKnownHostsToolError.stale)
  fixture.page.remove(single.entry, choice: .line)
  await knownHostsWait { fixture.notices.count == 2 && fixture.service.state == .loaded && !fixture.service.isRemoving }
  #expect(fixture.notices.last?.text == L("这条记录已在别处被修改，列表已重新加载"))
  #expect(fixture.notices.last?.isError == true)
  #expect(await fixture.fake.listCount == 3)
}

@Test("已知主机页：读取失败显示错误横幅；没有文件时显示空状态", arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func knownHostsPageShowsErrorAndEmptyStates(appearance: NSAppearance.Name) async throws {
  let fixture = await KnownHostsPageFixture(appearance: appearance, listing: SSHKnownHostsListing())
  defer { fixture.window.orderOut(nil) }
  await fixture.fake.setListError(SSHBrokerError.executableMissing)
  await fixture.appearAndLoad()
  let banner = try #require(findKnownHostsView("known-hosts-error", in: fixture.page.view))
  #expect(!banner.isHidden)
  #expect(fixture.service.state == .failed(L("找不到 aster-ssh，请重新构建 Aster.app")))
  #expect(fixture.page.reloadButton.isEnabled)
  try await captureKnownHostsWindow(fixture.window, name: "error")

  await fixture.fake.setListError(nil)
  fixture.service.refresh()
  await knownHostsWait { fixture.service.state == .loaded }
  fixture.window.contentView?.layoutSubtreeIfNeeded()
  #expect(banner.isHidden)
  let status = try #require(findKnownHostsView("known-hosts-status", in: fixture.page.view) as? NSTextField)
  #expect(status.stringValue == L("没有可列出的 known_hosts 文件。"))
  try await captureKnownHostsWindow(fixture.window, name: "empty")
}

@Test("主机页外壳：「已知主机」子页登记为原生页面")
@MainActor
func knownHostsPageRegisteredInHub() throws {
  let factory = try #require(HostsHubViewController.defaultFactories()[.knownHosts])
  #expect(factory() is KnownHostsPageViewController)
}

/// 按 identifier 递归找视图。
@MainActor
private func findKnownHostsView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for subview in root.subviews {
    if let found = findKnownHostsView(identifier, in: subview) { return found }
  }
  return nil
}
