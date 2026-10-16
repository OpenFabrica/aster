import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 设置页「主机 › 密钥」的桥接：经主机桥转发的动作、快照形状、导入（加密、重复）、生成、
// 删除与迁移引用、删除原文件前的核对与确认。全部用临时文件、内存钥匙串与假 `aster-ssh keys`。

/// 记录密钥桥的弹窗与剪贴板。
@MainActor
final class KeysBridgeRecorder {
  var toasts: [(text: String, isError: Bool)] = []
  var passphrases: [String?] = []
  var passphrasePrompts: [Bool] = []
  var pasteboard: [String] = []
  var deletePrompts: [SSHVaultDeleteOriginalPrompt] = []
  var confirmsDelete = true
  /// 确认框弹出时执行（模拟用户犹豫期间文件被替换）。
  var onConfirmDelete: (() throws -> Void)?
  var chosenFile: URL?
}

/// 测试夹具：临时 hosts.json / ssh-keys.json、内存钥匙串、假 `aster-ssh keys`，经主机桥接入。
@MainActor
struct KeysBridgeFixture {
  let root: URL
  let hostsBridge: SettingsHostsBridge
  let credentials = InMemoryVaultCredentials()
  let recorder = KeysBridgeRecorder()
  var keys: SSHVaultKeyDirectory { hostsBridge.keysBridge!.directory }
  var hosts: SSHHostDirectory { hostsBridge.directory }

  init(
    hosts: [SSHHostProfile] = [], tool: FakeVaultKeyTool = FakeVaultKeyTool(),
    listing: SSHConfigListing = SSHConfigListing()
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsterKeysBridge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hostStore = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
    try hostStore.save([.emptyDefaults()] + hosts)
    let hostDirectory = SSHHostDirectory(store: hostStore)
    let vault = SSHVaultKeyDirectory(
      store: SSHVaultKeyStore(fileURL: root.appendingPathComponent("ssh-keys.json")),
      credentials: credentials, hostDirectory: { hostDirectory })
    let recorder = recorder
    let keyDependencies = SettingsSSHKeysBridge.Dependencies(
      directory: vault,
      tool: { tool },
      chooseKeyFile: { _ in recorder.chosenFile },
      readKeyFile: SettingsSSHKeysBridge.readKeyFile,
      promptPassphrase: { _, isRetry in
        recorder.passphrasePrompts.append(isRetry)
        return recorder.passphrases.isEmpty ? nil : recorder.passphrases.removeFirst()
      },
      copyToPasteboard: { recorder.pasteboard.append($0) },
      confirmDeleteOriginal: { prompt, _ in
        recorder.deletePrompts.append(prompt)
        try? recorder.onConfirmDelete?()
        return recorder.confirmsDelete
      },
      configListing: { listing },
      engine: { .native },
      homeDirectory: root.path,
      localUser: "tester")
    hostsBridge = SettingsHostsBridge(
      dependencies: .init(
        directory: hostDirectory, passwords: FakeHostPasswords(), machines: { [] },
        machinesDidChange: nil, configListing: { listing },
        sshConfigURL: root.appendingPathComponent("ssh/config"), openInEditor: { _ in },
        addMachine: { _, _ in }, localUser: "tester", vaultKeys: keyDependencies))
    hostsBridge.toast = { recorder.toasts.append(($0, $1)) }
  }

  /// 执行一个动作并等待回执（同步动作立即回执）。
  func perform(_ action: String, _ payload: [String: Any] = [:]) async -> Bool {
    await withCheckedContinuation { continuation in
      hostsBridge.handle(action: action, payload: payload) { continuation.resume(returning: $0) }
    }
  }

  /// 在临时目录写一个私钥文件；`name` 可以带子目录（如 `.ssh/id_ed25519`），缺的目录自动创建。
  func writeKeyFile(_ name: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test("导入加密私钥：错一次 passphrase 后重试成功，私钥进钥匙串，目录只有公开信息")
@MainActor
func settingsKeysImportsEncryptedKey() async throws {
  let material = fakeVaultMaterial("enc", comment: "me@laptop")
  let fixture = try KeysBridgeFixture(
    tool: FakeVaultKeyTool(entries: ["ENCRYPTED": .init(material: material, passphrase: "right")]))
  defer { fixture.cleanUp() }
  fixture.recorder.chosenFile = try fixture.writeKeyFile("id_ed25519", "ENCRYPTED")
  fixture.recorder.passphrases = ["wrong", "right"]

  #expect(await fixture.perform("hosts.keys.import") == true)
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
  #expect(await fixture.perform("hosts.keys.import") == true)
  #expect(fixture.keys.keys.count == 1)
  #expect(fixture.credentials.vaultCount == 1)
}

@Test("导入：取消 passphrase 不落盘；三次都错则报错；无法识别的文件报错")
@MainActor
func settingsKeysImportFailures() async throws {
  let material = fakeVaultMaterial("enc")
  let fixture = try KeysBridgeFixture(
    tool: FakeVaultKeyTool(entries: ["ENCRYPTED": .init(material: material, passphrase: "right")]))
  defer { fixture.cleanUp() }
  fixture.recorder.chosenFile = try fixture.writeKeyFile("id_ed25519", "ENCRYPTED")
  #expect(await fixture.perform("hosts.keys.import") == false)
  fixture.recorder.passphrases = ["a", "b", "c"]
  #expect(await fixture.perform("hosts.keys.import") == false)
  #expect(fixture.recorder.toasts.last?.isError == true)
  fixture.recorder.chosenFile = try fixture.writeKeyFile("notes.txt", "hello")
  #expect(await fixture.perform("hosts.keys.import") == false)
  #expect(fixture.keys.keys.isEmpty)
  #expect(fixture.credentials.vaultCount == 0)
}

@Test("生成、改名、复制公钥；快照带 usedBy 与 keychainMissing")
@MainActor
func settingsKeysGenerateRenameCopy() async throws {
  let fixture = try KeysBridgeFixture(
    tool: FakeVaultKeyTool(generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  #expect(await fixture.perform("hosts.keys.generate", ["label": " 部署 ", "comment": "ci"]) == true)
  let key = try #require(fixture.keys.keys.first)
  #expect(key.label == "部署")
  #expect(key.comment == "ci")
  #expect(key.origin == .generated)

  #expect(await fixture.perform("hosts.keys.rename", ["id": key.id.uuidString, "label": "生产"]) == true)
  #expect(fixture.keys.key(key.id)?.label == "生产")
  #expect(await fixture.perform("hosts.keys.rename", ["id": key.id.uuidString, "label": "a\nb"]) == false)
  #expect(await fixture.perform("hosts.keys.copyPublicKey", ["id": key.id.uuidString]) == true)
  #expect(fixture.recorder.pasteboard == [key.publicKey])

  let host = SSHHostProfile(name: "db", host: "db", vaultKeyIDs: [key.id])
  try fixture.hosts.upsert(host)
  try fixture.credentials.deleteVaultPrivateKey(id: key.id)
  // 快照读的是缓存，刷新之后才看到缺失。
  await fixture.keys.refreshKeychainPresence().value
  let snapshot = fixture.hostsBridge.snapshot()
  let rows = try #require(snapshot["vaultKeys"] as? [[String: Any]])
  #expect(rows.first?["usedBy"] as? [String] == ["db"])
  #expect(rows.first?["keychainMissing"] as? Bool == true)
  #expect(rows.first?["origin"] as? String == "generated")
  #expect(snapshot["sshEngine"] as? String == "native")
  #expect(snapshot["vaultKeysError"] as? String == "")
}

@Test("删除密钥：目录、钥匙串与主机引用一起清理")
@MainActor
func settingsKeysDeleteClearsReferences() async throws {
  let fixture = try KeysBridgeFixture(tool: FakeVaultKeyTool(generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  #expect(await fixture.perform("hosts.keys.generate", ["label": "k"]) == true)
  let key = try #require(fixture.keys.keys.first)
  let host = SSHHostProfile(name: "db", host: "db", vaultKeyIDs: [key.id])
  try fixture.hosts.upsert(host)

  #expect(await fixture.perform("hosts.keys.delete", ["id": key.id.uuidString]) == true)
  #expect(fixture.keys.keys.isEmpty)
  #expect(!fixture.credentials.hasVaultPrivateKey(id: key.id))
  #expect(fixture.hosts.host(host.id)?.vaultKeyIDs == nil)
  #expect(await fixture.perform("hosts.keys.delete", ["id": key.id.uuidString]) == false)
}

@Test("目录保存失败时回滚钥匙串，不留孤儿私钥")
@MainActor
func sshVaultKeyDirectoryRollsBackKeychain() async throws {
  let fixture = try KeysBridgeFixture()
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
  // 钥匙串写入失败时目录不变。
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
