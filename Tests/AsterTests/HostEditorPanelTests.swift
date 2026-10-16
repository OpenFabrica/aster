// 主机页右侧编辑面板：新建 / 编辑 / 默认设置的打开、保存、取消与 Esc，未改动保存不丢字段。
// 口令操作与明暗截图在 `HostEditorPanelEvidenceTests.swift`。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 编辑面板测试用的临时 hosts.json、保险库密钥与内存钥匙串；不读写用户真实配置。
@MainActor
struct HostEditorFixture {
  let root: URL
  let directory: SSHHostDirectory
  let credentials = InMemoryVaultCredentials()
  let keys: [SSHVaultKey]
  let full: SSHHostProfile
  let jump: SSHHostProfile

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsterHostEditor-\(UUID().uuidString)", isDirectory: true)
    keys = [
      SSHVaultKey(
        label: "work-ed25519", algorithm: "ssh-ed25519", fingerprint: "SHA256:Qm9vZ2xlIGZpbmdlcnByaW50IGZvciB0ZXN0",
        publicKey: "ssh-ed25519 AAAA work", origin: .generated),
      SSHVaultKey(
        label: "deploy-rsa", algorithm: "ssh-rsa", fingerprint: "SHA256:ZGVwbG95IGtleSBmaW5nZXJwcmludCB0ZXN0",
        publicKey: "ssh-rsa AAAA deploy", origin: .imported),
    ]
    jump = SSHHostProfile(name: "bastion", group: "公司阿里云", host: "47.1.2.3", user: "ops")
    full = SSHHostProfile(
      name: "prod-db", group: "dx-test", host: "db.internal", port: 2222, user: "dba", jumpHostID: jump.id,
      proxyCommand: nil, socksProxy: SSHHostPort(host: "127.0.0.1", port: 1080), auth: .publicKey,
      identityFiles: ["~/.ssh/id_ed25519"], identitiesOnly: true, knownHostsFiles: ["~/.ssh/known_hosts_work"],
      identityAgent: "~/.1password/agent.sock", agentForward: true,
      forwards: [
        SSHForwardRule(
          kind: .local, bind: SSHHostPort(host: "127.0.0.1", port: 5432),
          target: SSHHostPort(host: "localhost", port: 5432), description: "Postgres"),
        SSHForwardRule(
          kind: .dynamic, bind: SSHHostPort(host: "127.0.0.1", port: 1081), target: SSHHostPort(host: "", port: 0)),
      ],
      keepaliveInterval: 30, keepaliveCountMax: 4, connectTimeout: 8, verifyHostKeys: true,
      tags: ["prod", "db"], vaultKeyIDs: [keys[1].id, UUID()])
    let defaults = SSHHostProfile(
      id: SSHHostProfile.defaultsProfileID, name: "Defaults", user: "deploy", identityFiles: ["~/.ssh/id_work"],
      keepaliveInterval: 20, vaultKeyIDs: [keys[0].id])
    let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
    try store.save([
      defaults, jump, full,
      SSHHostProfile(name: "app-server", group: "dx-test", host: "172.16.10.146", user: "dx"),
      SSHHostProfile(name: "lanmac mini", host: "lanmac.local", user: "mikelan", tags: ["home"]),
    ])
    directory = SSHHostDirectory(store: store)
    try credentials.setPassword("secret", for: "dba@db.internal:2222")
  }

  /// 注入替身依赖的编辑服务。
  var services: HostsPageEditorServices {
    let keys = keys
    return HostsPageEditorServices(
      vaultKeys: { keys }, credentials: credentials, machines: { [] }, addMachine: { _, _ in },
      sshConfigURL: root.appendingPathComponent("ssh/config"), openInEditor: { _ in })
  }
}

/// 把主机页放进主机页外壳与真实窗口，返回页面与窗口。
@MainActor
func makeEditorWindow(
  _ fixture: HostEditorFixture, appearance: NSAppearance.Name = .aqua
) throws -> (HostsPageViewController, NSWindow) {
  let suite = "HostEditor.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let model = AppModel(defaults: defaults)
  let page = HostsPageViewController(
    model: model, directory: fixture.directory, usageLedger: { HostUsageLedger() }, localUser: "tester",
    editorServices: fixture.services)
  let hub = HostsHubViewController(model: model, hostsPage: page, factories: [:])
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 860), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.appearance = NSAppearance(named: appearance)
  window.contentViewController = hub
  window.setContentSize(NSSize(width: 1_180, height: 860))
  window.contentView?.layoutSubtreeIfNeeded()
  return (page, window)
}

@Test("编辑面板：新建主机预填搜索地址与当前分组，填写后保存写入 hosts.json 并关闭")
@MainActor
func hostEditorCreatesHost() throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture)
  defer { window.orderOut(nil) }
  page.enterGroup("dx-test")
  page.searchField.stringValue = "root@203.0.113.9:2200"
  page.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
  page.createHost()
  let panel = try #require(page.editorPanel)
  #expect(panel.mode != .defaults && panel.view.superview === page.view)
  let form = panel.form!
  #expect(form.hostField?.stringValue == "203.0.113.9" && form.portField.stringValue == "2200")
  #expect(form.userField.stringValue == "root" && form.groupField?.stringValue == "dx-test")
  // 留空字段的占位符写出继承值：默认项的用户名与 keepalive，内置的端口。
  form.userField.stringValue = ""
  #expect(form.userField.field.placeholderString == "deploy")
  #expect(form.keepaliveIntervalField.field.placeholderString == "20")
  form.nameField?.stringValue = "edge"
  form.keepaliveCountField.stringValue = "6"
  panel.save()
  #expect(page.editorPanel == nil)
  let saved = try #require(fixture.directory.savedHosts.first { $0.name == "edge" })
  #expect(saved.host == "203.0.113.9" && saved.port == 2200 && saved.user == "" && saved.group == "dx-test")
  #expect(saved.keepaliveCountMax == 6 && saved.keepaliveInterval == nil)
}

@Test("编辑面板：取消与 Esc 不落盘；格式与校验错误显示在底栏且面板保留")
@MainActor
func hostEditorCancelEscAndErrors() throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture)
  defer { window.orderOut(nil) }
  let before = fixture.directory.hosts

  page.openEditor(.edit(fixture.full.id))
  var panel = try #require(page.editorPanel)
  panel.form.userField.stringValue = "changed"
  #expect(panel.isDirty)
  panel.cancel()
  #expect(page.editorPanel == nil && fixture.directory.hosts == before)

  page.openEditor(.edit(fixture.full.id))
  panel = try #require(page.editorPanel)
  panel.form.portField.stringValue = "22x"
  panel.form.socksField.stringValue = "1080"
  panel.save()
  #expect(page.editorPanel === panel && !panel.statusLabel.isHidden)
  #expect(panel.statusLabel.stringValue.contains(SSHHostDraftIssue.notInteger(.port).message))
  // 格式对了但存储校验不通过（端口越界）：原因同样显示在底栏。
  panel.form.portField.stringValue = "70000"
  panel.form.socksField.stringValue = ""
  panel.save()
  #expect(panel.statusLabel.stringValue.contains(L("端口必须在 1–65535 之间")))
  #expect(fixture.directory.hosts == before)
  // Esc（没有输入框接住时由面板根视图处理）关闭面板。
  panel.view.cancelOperation(nil)
  #expect(page.editorPanel == nil)
  // 单行输入框里的 Esc 同样关闭。
  page.openEditor(.edit(fixture.full.id))
  panel = try #require(page.editorPanel)
  _ = panel.control(
    panel.form.portField.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
  #expect(page.editorPanel == nil && fixture.directory.hosts == before)
}

@Test("编辑面板：不改动直接保存，主机全部字段原样保留；跳板候选灰显会成环的主机")
@MainActor
func hostEditorSaveWithoutChangesKeepsEveryField() throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture)
  defer { window.orderOut(nil) }
  let original = try #require(fixture.directory.host(fixture.full.id))

  page.openEditor(.edit(original.id))
  let panel = try #require(page.editorPanel)
  #expect(!panel.isDirty)
  #expect(panel.form.vaultKeys.selection == original.vaultKeyIDs)
  panel.save()
  #expect(page.editorPanel == nil)
  #expect(fixture.directory.host(original.id) == original)

  // 编辑跳板主机 bastion：prod-db 经它跳转，选 prod-db 作 bastion 的跳板会成环。
  page.openEditor(.edit(fixture.jump.id))
  let jumpPanel = try #require(page.editorPanel)
  let items = jumpPanel.form.jumpPopUp.popUp.itemArray
  let item = try #require(items.first(where: { ($0.representedObject as? UUID) == original.id }))
  #expect(!item.isEnabled)
  #expect(!jumpPanel.form.jumpPopUp.popUp.itemArray.contains { ($0.representedObject as? UUID) == fixture.jump.id })
}

@Test("编辑面板：默认设置只显示可继承字段、占位为内置值，保存写回默认项")
@MainActor
func hostEditorEditsDefaults() throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture)
  defer { window.orderOut(nil) }
  page.openEditor(.defaults)
  let panel = try #require(page.editorPanel)
  let form = panel.form!
  #expect(form.nameField == nil && form.hostField == nil && form.tagsField == nil)
  #expect(form.portField.field.placeholderString == "22")
  #expect(form.userField.field.placeholderString == "tester")
  #expect(form.keepaliveIntervalField.stringValue == "20")
  #expect(form.authPopUp.popUp.itemArray.first?.title == L("内置默认（\(L("自动"))）"))
  form.keepaliveIntervalField.stringValue = ""
  form.connectTimeoutField.stringValue = "12"
  panel.save()
  let stored = fixture.directory.hosts.first { $0.isDefaults }
  let defaults = try #require(stored)
  #expect(defaults.keepaliveInterval == nil && defaults.connectTimeout == 12 && defaults.user == "deploy")
  #expect(defaults.vaultKeyIDs == [fixture.keys[0].id])
}
