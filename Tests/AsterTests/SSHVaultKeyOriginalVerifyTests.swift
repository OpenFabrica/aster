// 保险库动作服务「删除原私钥文件」对磁盘文件的核对：文件被换成别的密钥、确认期间被替换、
// 加密私钥靠 .pub 核对、解析后不在 ~/.ssh 下，都拒绝删除。夹具见 SSHVaultActionsTestSupport.swift。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// `ssh-keygen -t ed25519 -C me@laptop` 生成的公钥及其指纹，用于加密私钥的 .pub 核对。
private let realPublicKey =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTYJWvaVFMKTBmpRfvvForC0KxD+MJTUCb7ynmlBqDa me@laptop"
private let realFingerprint = "SHA256:wQOc//ezWAIWB3kTbdhdvFDQov2cR0tddNWlQ44HUFM"

/// 假工具：PLAIN / OTHER 是两把未加密私钥，ENCRYPTED 是指纹为 `realFingerprint` 的加密私钥；
/// 钥匙串里存的规范化文本也能识别。
private func verifyTool() -> FakeVaultKeyTool {
  var encrypted = fakeVaultMaterial("enc")
  encrypted.fingerprint = realFingerprint
  encrypted.publicKey = realPublicKey
  return FakeVaultKeyTool(entries: [
    "PLAIN": .init(material: fakeVaultMaterial("p")),
    fakeVaultMaterial("p").privateKey: .init(material: fakeVaultMaterial("p")),
    "OTHER": .init(material: fakeVaultMaterial("other")),
    "ENCRYPTED": .init(material: encrypted, passphrase: "pw"),
    encrypted.privateKey: .init(material: encrypted),
  ])
}

@Test("删除原文件：文件已被换成另一把密钥或无法识别的内容时拒绝，不弹确认")
@MainActor
func vaultRefusesDeleteOriginalWhenFileReplaced() async throws {
  let fixture = try VaultActionsFixture(tool: verifyTool())
  defer { fixture.cleanUp() }
  let key = try await vaultImportPlainKey(fixture)
  let path = try #require(key.importedFrom)

  _ = try fixture.writeFile(".ssh/id_ed25519", "OTHER")
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  _ = try fixture.writeFile(".ssh/id_ed25519", "garbage")
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.deletePrompts.isEmpty)
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "garbage")
  #expect(fixture.recorder.toasts.last?.text.contains(SSHVaultKeyActionError.originalChanged.message) == true)
}

@Test("删除原文件：确认框打开期间文件被替换，删除前再次核对并拒绝")
@MainActor
func vaultRechecksOriginalAfterConfirmation() async throws {
  let fixture = try VaultActionsFixture(tool: verifyTool())
  defer { fixture.cleanUp() }
  let key = try await vaultImportPlainKey(fixture)
  let path = try #require(key.importedFrom)

  fixture.recorder.onConfirmDelete = { _ = try fixture.writeFile(".ssh/id_ed25519", "OTHER") }
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.deletePrompts.count == 1)
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "OTHER")
}

@Test("删除原文件：加密私钥用旁边 .pub 的指纹核对；.pub 缺失或对不上时拒绝")
@MainActor
func vaultVerifiesEncryptedOriginalByPublicKey() async throws {
  let fixture = try VaultActionsFixture(tool: verifyTool())
  defer { fixture.cleanUp() }
  fixture.recorder.chosenFile = try fixture.writeFile(".ssh/id_ed25519", "ENCRYPTED")
  fixture.recorder.passphrases = ["pw"]
  #expect(await fixture.actions.importKey() == true)
  let key = try #require(fixture.keys.keys.first)
  let path = try #require(key.importedFrom)

  // 没有 .pub：无法核对。
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.toasts.last?.text.contains(SSHVaultKeyActionError.originalUnverifiable.message) == true)
  // .pub 是另一把密钥：仍然拒绝。
  let otherPublic = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIQk5E3kZ8VHDa4fBk8QLEtHBcZsGgCdFBIAKtzSYVcF"
  _ = try fixture.writeFile(".ssh/id_ed25519.pub", otherPublic + "\n")
  #expect(await fixture.actions.deleteOriginal(key.id) == false)
  #expect(fixture.recorder.deletePrompts.isEmpty)
  #expect(FileManager.default.fileExists(atPath: path))
  // .pub 指纹一致：确认后删除，期间没有询问 passphrase。
  _ = try fixture.writeFile(".ssh/id_ed25519.pub", realPublicKey + "\n")
  let promptsBefore = fixture.recorder.passphrasePrompts.count
  #expect(await fixture.actions.deleteOriginal(key.id) == true)
  #expect(!FileManager.default.fileExists(atPath: path))
  #expect(fixture.recorder.passphrasePrompts.count == promptsBefore)
}

@Test("删除原文件：解析后不在 ~/.ssh 下时拒绝，包括 ~/.ssh 里指向外面的软链")
@MainActor
func vaultRefusesDeleteOriginalOutsideSSHDirectory() async throws {
  let fixture = try VaultActionsFixture(tool: verifyTool())
  defer { fixture.cleanUp() }
  let outside = try await vaultImportPlainKey(fixture, name: "keys/id_outside")
  #expect(await fixture.actions.deleteOriginal(outside.id) == false)
  #expect(fixture.recorder.toasts.last?.text.contains(
    SSHVaultKeyActionError.originalOutsideSSHDirectory.message) == true)
  #expect(FileManager.default.fileExists(atPath: try #require(outside.importedFrom)))

  // ~/.ssh/id_link → ~/keys/id_target：导入记录的是软链路径，解析后在外面。
  try FileManager.default.removeItem(atPath: try #require(outside.importedFrom))
  _ = try fixture.writeFile("keys/id_target", "OTHER")
  let link = fixture.root.appendingPathComponent(".ssh/id_link")
  try FileManager.default.createDirectory(
    at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    atPath: link.path, withDestinationPath: fixture.root.appendingPathComponent("keys/id_target").path)
  fixture.recorder.chosenFile = link
  #expect(await fixture.actions.importKey() == true)
  let linked = try #require(fixture.keys.keys.first { $0.fingerprint == "SHA256:other" })
  #expect(await fixture.actions.deleteOriginal(linked.id) == false)
  #expect(fixture.recorder.deletePrompts.isEmpty)
  #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("keys/id_target").path))
}
