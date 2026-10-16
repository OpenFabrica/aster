// 保险库动作服务 `SSHVaultKeyActions`：展示行、互斥、校验、未知密钥与钥匙串 I/O 不占主线程。
// 直接调用服务，不经界面；全部用临时文件、内存钥匙串与假 `aster-ssh keys`。
import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Test("展示行：按名称排序，带使用它的主机、可迁移主机、原文件与钥匙串缺失标记")
@MainActor
func vaultActionsRowsCarryUsageAndStatus() async throws {
  let user = SSHHostProfile(name: "web", host: "w", identityFiles: ["~/.ssh/id_work"])
  let fixture = try VaultActionsFixture(hosts: [user])
  defer { fixture.cleanUp() }
  let original = try fixture.writeFile(".ssh/id_work", "PLAIN")
  let work = try await fixture.addKey("w", label: "work", importedFrom: original.path)
  let deploy = try await fixture.addKey("d", label: "Deploy")
  var defaults = try #require(fixture.hosts.hosts.first { $0.isDefaults })
  defaults.vaultKeyIDs = [deploy.id]
  try fixture.hosts.upsert(defaults)
  try fixture.hosts.upsert(SSHHostProfile(name: "mysql", host: "mysql", vaultKeyIDs: [deploy.id]))
  try fixture.credentials.deleteVaultPrivateKey(id: deploy.id)
  await fixture.keys.refreshKeychainPresence().value

  let rows = fixture.actions.rows(hosts: fixture.hosts.hosts)
  #expect(rows.map(\.key.label) == ["Deploy", "work"])
  #expect(rows[0].usedBy == [L("默认"), "mysql"])
  #expect(rows[0].keychainMissing)
  #expect(!rows[0].canDeleteOriginal)
  #expect(rows[0].originText == L("在 Aster 中生成"))
  #expect(rows[1].migratableHosts == ["web"])
  #expect(rows[1].originalExists && rows[1].canDeleteOriginal)
  #expect(!rows[1].keychainMissing)

  // 搜索：名称、主机名、指纹都能命中，不区分大小写。搜索词要含十六进制以外的字母：
  // 原文件路径在带随机 UUID 的临时目录里，像 "db" 这样的词会偶尔命中路径。
  #expect(rows.filter { $0.matches("DEPLOY") }.map(\.id) == [deploy.id])
  #expect(rows.filter { $0.matches("mysql") }.map(\.id) == [deploy.id])
  #expect(rows.filter { $0.matches("sha256:w") }.map(\.id) == [work.id])
  #expect(rows.filter { $0.matches("  ") }.count == 2)
  #expect(SSHVaultKeyRow.shortFingerprint("SHA256:abcdefghijklmnopqrstu") == "SHA256:abcdefghijklmnop…")
  #expect(SSHVaultKeyRow.shortFingerprint("SHA256:short") == "SHA256:short")
  #expect(SSHVaultKeyRow.shortFingerprint("MD5:aa") == "MD5:aa")
}

@Test("互斥：导入等待文件面板期间，删除与生成直接返回失败；结束后 isBusy 复位")
@MainActor
func vaultActionsAreExclusive() async throws {
  let tool = FakeVaultKeyTool(
    entries: ["PLAIN": .init(material: fakeVaultMaterial("p"))], generated: fakeVaultMaterial("g"))
  let fixture = try VaultActionsFixture(tool: tool)
  defer { fixture.cleanUp() }
  let existing = try await fixture.addKey("e", label: "existing")
  fixture.recorder.chosenFile = try fixture.writeFile(".ssh/id_ed25519", "PLAIN")
  fixture.recorder.holdsChooser = true

  let importing = Task { @MainActor in await fixture.actions.importKey() }
  while fixture.recorder.chooserGate == nil { await Task.yield() }
  #expect(fixture.actions.isBusy)
  #expect(await fixture.actions.delete(existing.id) == false)
  #expect(await fixture.actions.generate(label: "x", comment: "") == false)
  #expect(fixture.keys.key(existing.id) != nil)

  fixture.recorder.releaseChooser()
  #expect(await importing.value == true)
  #expect(!fixture.actions.isBusy)
  #expect(fixture.keys.keys.count == 2)
  #expect(fixture.recorder.toasts.last?.isError == false)
}

@Test("校验：名称与注释在占用互斥前检查；未知密钥与生成的密钥给出明确错误")
@MainActor
func vaultActionsValidateInputs() async throws {
  let fixture = try VaultActionsFixture(tool: FakeVaultKeyTool(generated: fakeVaultMaterial("g")))
  defer { fixture.cleanUp() }
  #expect(await fixture.actions.generate(label: "  ", comment: "") == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.invalidLabel.message)
  #expect(await fixture.actions.generate(label: "k", comment: String(repeating: "c", count: 257)) == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.invalidComment.message)
  #expect(fixture.keys.keys.isEmpty)

  #expect(await fixture.actions.generate(label: " 部署 ", comment: " ci ") == true)
  let key = try #require(fixture.keys.keys.first)
  #expect(key.label == "部署" && key.comment == "ci")

  let missing = UUID()
  #expect(fixture.actions.rename(missing, label: "x") == false)
  #expect(fixture.actions.copyPublicKey(missing) == false)
  #expect(await fixture.actions.delete(missing) == false)
  #expect(await fixture.actions.deleteOriginal(missing) == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.unknownKey.message)
  // 生成的密钥没有原文件：迁移与删除原文件都拒绝。
  #expect(fixture.actions.migrateReferences(key.id) == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.notImported.message)
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.notImported.message)
  #expect(!fixture.actions.isBusy)
}

@Test("钥匙串读写不占主线程；onChange 在每次改动后调用")
@MainActor
func vaultActionsKeepKeychainOffMain() async throws {
  let tool = FakeVaultKeyTool(
    entries: ["PLAIN": .init(material: fakeVaultMaterial("p"))], generated: fakeVaultMaterial("g"))
  let fixture = try VaultActionsFixture(tool: tool)
  defer { fixture.cleanUp() }
  var changes = 0
  fixture.actions.onChange = { changes += 1 }
  fixture.recorder.chosenFile = try fixture.writeFile(".ssh/id_ed25519", "PLAIN")
  #expect(await fixture.actions.importKey() == true)
  #expect(await fixture.actions.generate(label: "g", comment: "") == true)
  let generated = try #require(fixture.keys.keys.first { $0.origin == .generated })
  #expect(fixture.actions.rename(generated.id, label: "renamed") == true)
  #expect(fixture.actions.copyPublicKey(generated.id) == true)
  #expect(fixture.recorder.pasteboard == [generated.publicKey])
  #expect(await fixture.actions.delete(generated.id) == true)
  #expect(changes == 4)
  #expect(fixture.credentials.takeMainThreadVaultCalls().isEmpty)
}
