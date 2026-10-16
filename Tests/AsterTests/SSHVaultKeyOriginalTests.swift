// 保险库动作服务里与原私钥文件相关的动作：把主机引用迁到保险库、删除原文件前的钥匙串核对与确认框内容，
// 以及 `~/.ssh` 目录判定。磁盘文件被替换等核对见 SSHVaultKeyOriginalVerifyTests.swift。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 经服务导入一把未加密私钥（默认放在夹具家目录的 `~/.ssh` 下），返回保险库条目。
@MainActor
func vaultImportPlainKey(_ fixture: VaultActionsFixture, name: String = ".ssh/id_ed25519") async throws
  -> SSHVaultKey
{
  fixture.recorder.chosenFile = try fixture.writeFile(name, "PLAIN")
  #expect(await fixture.actions.importKey() == true)
  let path = fixture.root.appendingPathComponent(name).standardizedFileURL.path
  return try #require(fixture.keys.keys.first { $0.importedFrom == path })
}

@Test("迁移引用：identityFiles 指向原文件的主机改用保险库密钥，其它主机不动，展示行随之更新")
@MainActor
func vaultMigratesOriginalReferences() async throws {
  let tool = FakeVaultKeyTool(entries: ["PLAIN": .init(material: fakeVaultMaterial("p"))])
  let user = SSHHostProfile(name: "uses", host: "a", identityFiles: ["~/.ssh/id_ed25519"])
  let other = SSHHostProfile(name: "other", host: "b", identityFiles: ["~/.ssh/id_rsa"])
  let fixture = try VaultActionsFixture(hosts: [user, other], tool: tool)
  defer { fixture.cleanUp() }
  let key = try await vaultImportPlainKey(fixture)

  let before = try #require(fixture.actions.rows(hosts: fixture.hosts.hosts).first)
  #expect(before.migratableHosts == ["uses"])
  #expect(before.originalExists)

  #expect(fixture.actions.migrateReferences(key.id) == true)
  #expect(fixture.hosts.host(user.id)?.identityFiles == [])
  #expect(fixture.hosts.host(user.id)?.vaultKeyIDs == [key.id])
  #expect(fixture.hosts.host(other.id) == other)
  let after = try #require(fixture.actions.rows(hosts: fixture.hosts.hosts).first)
  #expect(after.migratableHosts.isEmpty)
  #expect(after.usedBy == ["uses"])
}

@Test("删除原文件：核对钥匙串，确认框列出仍引用它的主机与 ssh_config 别名，确认后直接删除")
@MainActor
func vaultDeletesOriginalAfterVerification() async throws {
  let tool = FakeVaultKeyTool(entries: [
    "PLAIN": .init(material: fakeVaultMaterial("p")),
    fakeVaultMaterial("p").privateKey: .init(material: fakeVaultMaterial("p")),
  ])
  let user = SSHHostProfile(name: "uses", host: "a", identityFiles: ["~/.ssh/id_ed25519"])
  let listing = SSHConfigListing(hosts: [
    SSHConfigHostEntry(alias: "prod", identityFiles: ["~/.ssh/id_ed25519"]),
    SSHConfigHostEntry(alias: "dev", identityFiles: ["~/.ssh/id_rsa"]),
  ])
  let fixture = try VaultActionsFixture(hosts: [user], tool: tool, listing: listing)
  defer { fixture.cleanUp() }
  let key = try await vaultImportPlainKey(fixture)
  let path = try #require(key.importedFrom)

  // 用户取消：文件保留。
  fixture.recorder.confirmsDeleteOriginal = false
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(FileManager.default.fileExists(atPath: path))
  let prompt = try #require(fixture.recorder.deletePrompts.first)
  #expect(prompt.hostNames == ["uses"])
  #expect(prompt.sshConfigAliases == ["prod"])

  fixture.recorder.confirmsDeleteOriginal = true
  #expect(await fixture.actions.deleteOriginal(key.id) == true)
  #expect(!FileManager.default.fileExists(atPath: path))
  // 私钥仍在钥匙串里。
  #expect(fixture.credentials.hasVaultPrivateKey(id: key.id))
  // 文件已不存在时不再允许删除。
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.originalMissing.message)
}

@Test("删除原文件：钥匙串里的私钥缺失或指纹不符时取消，不弹确认、不删文件")
@MainActor
func vaultRefusesDeleteOriginalWhenKeychainMismatch() async throws {
  let tool = FakeVaultKeyTool(entries: [
    "PLAIN": .init(material: fakeVaultMaterial("p")),
    "TAMPERED": .init(material: fakeVaultMaterial("other")),
  ])
  let fixture = try VaultActionsFixture(tool: tool)
  defer { fixture.cleanUp() }
  let key = try await vaultImportPlainKey(fixture)
  let path = try #require(key.importedFrom)

  try fixture.credentials.setVaultPrivateKey("TAMPERED", id: key.id, label: "x")
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.toasts.last?.text.contains(SSHVaultKeyActionError.verificationFailed.message) == true)
  try fixture.credentials.deleteVaultPrivateKey(id: key.id)
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.deletePrompts.isEmpty)
  #expect(FileManager.default.fileExists(atPath: path))
}

@Test("~/.ssh 判定：解析软链后比较，目录本身与同名前缀目录都不算在内")
func vaultSSHDirectoryContainment() {
  let home = "/Users/tester"
  #expect(SSHVaultKeyActions.isInsideSSHDirectory("/Users/tester/.ssh/id_ed25519", homeDirectory: home))
  #expect(SSHVaultKeyActions.isInsideSSHDirectory("/Users/tester/.ssh/sub/key", homeDirectory: home))
  #expect(!SSHVaultKeyActions.isInsideSSHDirectory("/Users/tester/.ssh", homeDirectory: home))
  #expect(!SSHVaultKeyActions.isInsideSSHDirectory("/Users/tester/.ssh2/key", homeDirectory: home))
  #expect(!SSHVaultKeyActions.isInsideSSHDirectory("/Users/tester/key", homeDirectory: home))
}
