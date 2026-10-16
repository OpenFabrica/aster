import Foundation
import Testing

@testable import AsterCore

// 测 SSHVaultKeyStore：首次启动、round-trip 与 0600 权限、整份校验（重复 ID / 指纹、
// 名称、公钥格式）、损坏文件保留最后有效快照。

/// 一把合法的元数据；`seed` 决定公钥与指纹。
private func vaultKey(_ seed: String, label: String? = nil, id: UUID = UUID()) -> SSHVaultKey {
  let blob = Data("key-\(seed)".utf8).base64EncodedString()
  return SSHVaultKey(
    id: id, label: label ?? "key \(seed)", algorithm: "ssh-ed25519", fingerprint: "SHA256:\(seed)",
    publicKey: "ssh-ed25519 \(blob) \(seed)@test", comment: "\(seed)@test",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000), origin: .imported,
    importedFrom: "/Users/tester/.ssh/id_\(seed)")
}

/// 临时目录里的存储。
private func temporaryStore() -> (SSHVaultKeyStore, URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterVaultStore-\(UUID().uuidString)", isDirectory: true)
  return (SSHVaultKeyStore(fileURL: root.appendingPathComponent("ssh-keys.json")), root)
}

@Test("保险库目录：文件不存在时是空列表")
func sshVaultKeyStoreLoadsEmptyWhenMissing() throws {
  let (store, root) = temporaryStore()
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(try store.load().isEmpty)
}

@Test("保险库目录：保存后原样读回，文件权限 0600，日期为 ISO 8601")
func sshVaultKeyStoreRoundTrips() throws {
  let (store, root) = temporaryStore()
  defer { try? FileManager.default.removeItem(at: root) }
  let keys = [vaultKey("a"), vaultKey("b")]
  try store.save(keys)
  #expect(try SSHVaultKeyStore(fileURL: store.fileURL).load() == keys)
  let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let text = try String(contentsOf: store.fileURL, encoding: .utf8)
  #expect(text.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
  #expect(!text.contains("PRIVATE KEY"))
}

@Test("保险库目录：重复 ID、重复指纹、非法名称与公钥都被拒绝且不落盘")
func sshVaultKeyStoreValidates() throws {
  let (store, root) = temporaryStore()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = vaultKey("a")
  var sameFingerprint = vaultKey("b")
  sameFingerprint.fingerprint = a.fingerprint
  var sameID = vaultKey("c", id: a.id)
  sameID.fingerprint = "SHA256:c"
  var badLabel = vaultKey("d", label: "line\nbreak")
  badLabel.label = "line\nbreak"
  var longLabel = vaultKey("e")
  longLabel.label = String(repeating: "长", count: 30)
  var badKey = vaultKey("f")
  badKey.publicKey = "ssh-dss AAAA"
  var mismatched = vaultKey("g")
  mismatched.algorithm = "ssh-rsa"

  let reasons = SSHVaultKeyStore.validate(
    [a, sameFingerprint, sameID, badLabel, longLabel, badKey, mismatched])
  #expect(reasons.contains("[1] duplicate fingerprint"))
  #expect(reasons.contains("[2] duplicate id"))
  #expect(reasons.contains("[3] invalid label"))
  #expect(reasons.contains("[4] invalid label"))
  #expect(reasons.contains("[5] invalid public key"))
  #expect(reasons.contains("[6] invalid public key"))
  #expect(throws: SSHVaultKeyStoreError.self) { try store.save([a, sameFingerprint]) }
  #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
}

@Test("保险库目录：损坏文件报错，有效快照保持上一次的值")
func sshVaultKeyStoreKeepsLastValidOnCorruption() throws {
  let (store, root) = temporaryStore()
  defer { try? FileManager.default.removeItem(at: root) }
  let keys = [vaultKey("a")]
  try store.save(keys)
  try Data("{not json".utf8).write(to: store.fileURL)
  #expect(throws: SSHVaultKeyStoreError.self) { try store.load() }
  #expect(store.effectiveKeys == keys)
  try Data(#"{"version":9,"keys":[]}"#.utf8).write(to: store.fileURL)
  #expect(throws: SSHVaultKeyStoreError.self) { try store.load() }
}
