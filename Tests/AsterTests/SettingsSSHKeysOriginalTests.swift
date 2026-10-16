import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 「密钥」子页里与原私钥文件相关的动作：把主机引用迁到保险库、删除原文件前的钥匙串核对与确认；
// 以及主机桥在保存、复制时保留 vaultKeyIDs（字段丢失陷阱）。

/// 导入一把未加密的私钥文件，返回保险库条目。
@MainActor
private func importPlainKey(_ fixture: KeysBridgeFixture, name: String = "id_ed25519") async throws
  -> SSHVaultKey
{
  fixture.recorder.chosenFile = try fixture.writeKeyFile(name, "PLAIN")
  #expect(await fixture.perform("hosts.keys.import") == true)
  return try #require(fixture.keys.keys.first)
}

@Test("迁移引用：identityFiles 指向原文件的主机改用保险库密钥，快照随之更新")
@MainActor
func settingsKeysMigratesReferences() async throws {
  let tool = FakeVaultKeyTool(entries: ["PLAIN": .init(material: fakeVaultMaterial("p"))])
  let user = SSHHostProfile(name: "uses", host: "a", identityFiles: ["~/id_ed25519"])
  let other = SSHHostProfile(name: "other", host: "b", identityFiles: ["~/id_rsa"])
  let fixture = try KeysBridgeFixture(hosts: [user, other], tool: tool)
  defer { fixture.cleanUp() }
  let key = try await importPlainKey(fixture)

  let before = try #require(fixture.hostsBridge.snapshot()["vaultKeys"] as? [[String: Any]])
  #expect(before.first?["migratableHosts"] as? [String] == ["uses"])
  #expect(before.first?["originalExists"] as? Bool == true)

  #expect(await fixture.perform("hosts.keys.migrateReferences", ["id": key.id.uuidString]) == true)
  #expect(fixture.hosts.host(user.id)?.identityFiles == [])
  #expect(fixture.hosts.host(user.id)?.vaultKeyIDs == [key.id])
  #expect(fixture.hosts.host(other.id) == other)
  let after = try #require(fixture.hostsBridge.snapshot()["vaultKeys"] as? [[String: Any]])
  #expect(after.first?["migratableHosts"] as? [String] == [])
  #expect(after.first?["usedBy"] as? [String] == ["uses"])
}

@Test("删除原文件：核对钥匙串、列出仍引用它的主机与 ssh_config，确认后直接删除")
@MainActor
func settingsKeysDeletesOriginalAfterVerification() async throws {
  let tool = FakeVaultKeyTool(entries: [
    "PLAIN": .init(material: fakeVaultMaterial("p")),
    fakeVaultMaterial("p").privateKey: .init(material: fakeVaultMaterial("p")),
  ])
  let user = SSHHostProfile(name: "uses", host: "a", identityFiles: ["~/id_ed25519"])
  let listing = SSHConfigListing(hosts: [
    SSHConfigHostEntry(alias: "prod", identityFiles: ["~/id_ed25519"]),
    SSHConfigHostEntry(alias: "dev", identityFiles: ["~/id_rsa"]),
  ])
  let fixture = try KeysBridgeFixture(hosts: [user], tool: tool, listing: listing)
  defer { fixture.cleanUp() }
  let key = try await importPlainKey(fixture)
  let path = try #require(key.importedFrom)

  // 用户取消：文件保留。
  fixture.recorder.confirmsDelete = false
  #expect(await fixture.perform("hosts.keys.deleteOriginal", ["id": key.id.uuidString]) == false)
  #expect(FileManager.default.fileExists(atPath: path))
  let prompt = try #require(fixture.recorder.deletePrompts.first)
  #expect(prompt.hostNames == ["uses"])
  #expect(prompt.sshConfigAliases == ["prod"])

  fixture.recorder.confirmsDelete = true
  #expect(await fixture.perform("hosts.keys.deleteOriginal", ["id": key.id.uuidString]) == true)
  #expect(!FileManager.default.fileExists(atPath: path))
  // 私钥仍在钥匙串里。
  #expect(fixture.credentials.hasVaultPrivateKey(id: key.id))
  // 文件已不存在时不再允许删除。
  #expect(await fixture.perform("hosts.keys.deleteOriginal", ["id": key.id.uuidString]) == false)
}

@Test("删除原文件：钥匙串里的私钥缺失或指纹不符时取消，不弹确认、不删文件")
@MainActor
func settingsKeysRefusesDeleteOriginalWhenKeychainMismatch() async throws {
  let tool = FakeVaultKeyTool(entries: [
    "PLAIN": .init(material: fakeVaultMaterial("p")),
    "TAMPERED": .init(material: fakeVaultMaterial("other")),
  ])
  let fixture = try KeysBridgeFixture(tool: tool)
  defer { fixture.cleanUp() }
  let key = try await importPlainKey(fixture)
  let path = try #require(key.importedFrom)

  try fixture.credentials.setVaultPrivateKey("TAMPERED", id: key.id, label: "x")
  #expect(await fixture.perform("hosts.keys.deleteOriginal", ["id": key.id.uuidString]) == false)
  try fixture.credentials.deleteVaultPrivateKey(id: key.id)
  #expect(await fixture.perform("hosts.keys.deleteOriginal", ["id": key.id.uuidString]) == false)
  #expect(fixture.recorder.deletePrompts.isEmpty)
  #expect(FileManager.default.fileExists(atPath: path))
}

@Test("主机桥保存与复制都保留 vaultKeyIDs；空列表存成 nil")
@MainActor
func settingsHostsCarriesVaultKeyIDs() async throws {
  let fixture = try KeysBridgeFixture()
  defer { fixture.cleanUp() }
  let ids = [UUID(), UUID()]
  let host = SSHHostProfile(name: "db", host: "db", vaultKeyIDs: ids)
  let object = SettingsHostsBridge.profileJSON(host)
  #expect(object["vaultKeyIDs"] as? [String] == ids.map(\.uuidString))
  #expect(await fixture.perform("hosts.save", ["profile": object]) == true)
  #expect(fixture.hosts.host(host.id)?.vaultKeyIDs == ids)

  #expect(await fixture.perform("hosts.duplicate", ["id": host.id.uuidString]) == true)
  let copy = try #require(fixture.hosts.savedHosts.first { $0.id != host.id })
  #expect(copy.vaultKeyIDs == ids)

  var cleared = object
  cleared["vaultKeyIDs"] = [String]()
  #expect(await fixture.perform("hosts.save", ["profile": cleared]) == true)
  #expect(fixture.hosts.host(host.id)?.vaultKeyIDs == nil)
}
