// 保险库动作服务的导入、改名与删除：加密私钥的 passphrase 重试、重复导入复用条目、取消与失败不落盘、
// 删除时清理主机引用，以及目录保存失败时回滚钥匙串。直接调用 `SSHVaultKeyActions` 与 `SSHVaultKeyDirectory`。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Test("导入加密私钥：错一次 passphrase 后重试成功，私钥进钥匙串，目录只有公开信息；再导入复用已有条目")
@MainActor
func vaultImportEncryptedKeyRetriesPassphrase() async throws {
  let material = fakeVaultMaterial("enc", comment: "me@laptop")
  let fixture = try VaultActionsFixture(
    tool: FakeVaultKeyTool(entries: ["ENCRYPTED": .init(material: material, passphrase: "right")]))
  defer { fixture.cleanUp() }
  fixture.recorder.chosenFile = try fixture.writeFile("id_ed25519", "ENCRYPTED")
  fixture.recorder.passphrases = ["wrong", "right"]

  #expect(await fixture.actions.importKey() == true)
  #expect(fixture.recorder.passphrasePrompts == [false, true])
  let key = try #require(fixture.keys.keys.first)
  #expect(key.label == "id_ed25519 (me@laptop)")
  #expect(key.origin == .imported)
  #expect(key.importedFrom == fixture.root.appendingPathComponent("id_ed25519").standardizedFileURL.path)
  #expect(try fixture.credentials.vaultPrivateKey(id: key.id) == material.privateKey)
  let file = try String(contentsOf: fixture.keys.store.fileURL, encoding: .utf8)
  #expect(!file.contains("PRIVATE KEY"))

  // 同一把密钥再导入一次：复用已有条目，不新增钥匙串条目。
  fixture.recorder.passphrases = ["right"]
  #expect(await fixture.actions.importKey() == true)
  #expect(fixture.keys.keys.count == 1)
  #expect(fixture.credentials.vaultCount == 1)
}

@Test("导入：取消 passphrase 不落盘；三次都错则报错；无法识别的文件报错")
@MainActor
func vaultImportFailuresLeaveVaultEmpty() async throws {
  let material = fakeVaultMaterial("enc")
  let fixture = try VaultActionsFixture(
    tool: FakeVaultKeyTool(entries: ["ENCRYPTED": .init(material: material, passphrase: "right")]))
  defer { fixture.cleanUp() }
  fixture.recorder.chosenFile = try fixture.writeFile("id_ed25519", "ENCRYPTED")
  // passphrase 队列为空等同于用户取消：不提示错误。
  #expect(await fixture.actions.importKey() == false)
  #expect(fixture.recorder.toasts.isEmpty)

  fixture.recorder.passphrases = ["a", "b", "c"]
  #expect(await fixture.actions.importKey() == false)
  #expect(fixture.recorder.passphrasePrompts.suffix(3) == [false, true, true])
  #expect(fixture.recorder.toasts.last?.isError == true)

  fixture.recorder.chosenFile = try fixture.writeFile("notes.txt", "hello")
  #expect(await fixture.actions.importKey() == false)
  #expect(fixture.recorder.toasts.last?.isError == true)
  #expect(fixture.keys.keys.isEmpty)
  #expect(fixture.credentials.vaultCount == 0)
}

@Test("改名拒绝换行；删除密钥时目录、钥匙串与主机引用一起清理，再删报不存在")
@MainActor
func vaultRenameAndDeleteClearReferences() async throws {
  let fixture = try VaultActionsFixture(tool: FakeVaultKeyTool(generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  #expect(await fixture.actions.generate(label: "k", comment: "") == true)
  let key = try #require(fixture.keys.keys.first)
  #expect(fixture.actions.rename(key.id, label: "a\nb") == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.invalidLabel.message)
  #expect(fixture.keys.key(key.id)?.label == "k")

  let host = SSHHostProfile(name: "db", host: "db", vaultKeyIDs: [key.id])
  try fixture.hosts.upsert(host)
  #expect(await fixture.actions.delete(key.id) == true)
  #expect(fixture.keys.keys.isEmpty)
  #expect(!fixture.credentials.hasVaultPrivateKey(id: key.id))
  #expect(fixture.hosts.host(host.id)?.vaultKeyIDs == nil)
  #expect(await fixture.actions.delete(key.id) == false)
  #expect(fixture.recorder.toasts.last?.text == SSHVaultKeyActionError.unknownKey.message)
}

@Test("目录保存失败时回滚钥匙串，不留孤儿私钥；钥匙串写入失败时目录不变")
@MainActor
func vaultDirectoryRollsBackKeychain() async throws {
  let fixture = try VaultActionsFixture()
  defer { fixture.cleanUp() }
  let material = fakeVaultMaterial("a")
  let first = SSHVaultKey(
    label: "a", algorithm: material.algorithm, fingerprint: material.fingerprint,
    publicKey: material.publicKey, origin: .generated)
  try await fixture.keys.add(first, privateKey: material.privateKey)
  // 指纹重复，目录校验失败。
  let duplicate = SSHVaultKey(
    label: "b", algorithm: material.algorithm, fingerprint: material.fingerprint,
    publicKey: material.publicKey, origin: .generated)
  await #expect(throws: SSHVaultKeyDirectoryError.self) {
    try await fixture.keys.add(duplicate, privateKey: material.privateKey)
  }
  #expect(!fixture.credentials.hasVaultPrivateKey(id: duplicate.id))
  #expect(fixture.credentials.hasVaultPrivateKey(id: first.id))

  fixture.credentials.setFailsVaultWrites(true)
  let other = fakeVaultMaterial("b")
  await #expect(throws: SSHVaultKeyDirectoryError.self) {
    try await fixture.keys.add(
      SSHVaultKey(
        label: "c", algorithm: other.algorithm, fingerprint: other.fingerprint,
        publicKey: other.publicKey, origin: .generated),
      privateKey: other.privateKey)
  }
  #expect(fixture.keys.keys == [first])
}
