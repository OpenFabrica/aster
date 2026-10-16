// 「主机 → 密钥」原生子页的动作流程：经假对话框的生成 / 重命名 / 迁移 / 删除。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 假对话框：按队列返回名称表单结果，记录每次弹出的请求与确认。
@MainActor
final class FakeKeysPrompts {
  var names: [HostsKeyNameResult?] = []
  var nameRequests: [HostsKeyNameRequest] = []
  var confirms = true
  var deletePrompts: [String] = []
  var migratePrompts: [[String]] = []

  /// 交给页面的对话框集合。
  var prompts: HostsKeysPrompts {
    HostsKeysPrompts(
      name: { [unowned self] request, _ in
        self.nameRequests.append(request)
        return self.names.isEmpty ? nil : self.names.removeFirst()
      },
      confirmDelete: { [unowned self] row, _ in
        self.deletePrompts.append(row.key.label)
        return self.confirms
      },
      confirmMigrate: { [unowned self] row, _ in
        self.migratePrompts.append(row.migratableHosts)
        return self.confirms
      })
  }
}

@Test("密钥页动作：生成失败后带原因重弹表单；重命名、迁移、删除都先确认再交给服务")
@MainActor
func hostsKeysPageActionsUsePrompts() async throws {
  let jump = SSHHostProfile(name: "jump", host: "jump.example.com", identityFiles: ["~/.ssh/id_ed25519"])
  let fixture = try KeysPageFixture(
    hosts: [jump], tool: FakeVaultKeyTool(generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  let page = fixture.page
  let prompts = fixture.fakePrompts

  // 生成：第一次名称含换行被拒，表单带原因与原输入重弹；第二次成功并选中新密钥。
  prompts.names = [HostsKeyNameResult(label: "a\nb", comment: "ci"), HostsKeyNameResult(label: "部署", comment: "ci")]
  page.generateKey()
  while prompts.nameRequests.count < 2 || fixture.vault.keys.keys.isEmpty { await Task.yield() }
  #expect(prompts.nameRequests[1].error == SSHVaultKeyActionError.invalidLabel.message)
  #expect(prompts.nameRequests[1].comment == "ci")
  let generated = try #require(fixture.vault.keys.keys.first)
  while page.selectedID != generated.id { await Task.yield() }
  #expect(generated.label == "部署")

  // 重命名：预填当前名称。
  prompts.names = [HostsKeyNameResult(label: "生产", comment: "")]
  page.renameKey(generated.id)
  while fixture.vault.keys.key(generated.id)?.label != "生产" { await Task.yield() }
  #expect(prompts.nameRequests.last == HostsKeyNameRequest(mode: .rename, label: "部署"))

  // 迁移：确认框列出要改的主机，确认后 identityFiles 换成保险库引用。
  let original = try fixture.vault.writeFile(".ssh/id_ed25519", "PLAIN")
  let imported = try await fixture.vault.addKey("imp", label: "imported", importedFrom: original.path)
  fixture.settle()
  page.migrateReferences(imported.id)
  while fixture.vault.hosts.host(jump.id)?.vaultKeyIDs != [imported.id] { await Task.yield() }
  #expect(prompts.migratePrompts == [["jump"]])

  // 删除：取消时不动；确认后目录与选择一起清掉。
  page.select(generated.id)
  prompts.confirms = false
  page.deleteKey(generated.id)
  while prompts.deletePrompts.count < 1 { await Task.yield() }
  await Task.yield()
  #expect(fixture.vault.keys.key(generated.id) != nil)
  prompts.confirms = true
  page.deleteKey(generated.id)
  while fixture.vault.keys.key(generated.id) != nil || page.selectedID != nil { await Task.yield() }
  #expect(prompts.deletePrompts == ["生产", "生产"])
  #expect(!fixture.vault.credentials.hasVaultPrivateKey(id: generated.id))
}
