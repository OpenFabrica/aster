// 私钥保险库测试共用的替身：内存钥匙串与可编排的 `aster-ssh keys`。
// 都不碰真实钥匙串，也不启动子进程。
import AsterCore
import Foundation
import os

@testable import Aster

/// 内存凭证存储，含保险库私钥。锁保护字典，满足 `Sendable` 而不需要 `@unchecked`。
final class InMemoryVaultCredentials: SSHCredentialStoring {
  private let entries = OSAllocatedUnfairLock(initialState: [String: String]())
  /// 为 true 时写入保险库私钥失败（模拟钥匙串拒绝）。
  private let failsVaultWrites = OSAllocatedUnfairLock(initialState: false)

  /// 在主线程上发生的保险库调用（方法名），用来断言钥匙串 I/O 不占主线程。
  private let mainThreadVaultCalls = OSAllocatedUnfairLock(initialState: [String]())

  /// 让后续的保险库写入失败或恢复正常。
  func setFailsVaultWrites(_ fails: Bool) { failsVaultWrites.withLock { $0 = fails } }

  /// 读出并清空主线程上的保险库调用记录。
  func takeMainThreadVaultCalls() -> [String] {
    mainThreadVaultCalls.withLock { calls in
      defer { calls = [] }
      return calls
    }
  }

  /// 调用发生在主线程时记一笔。
  private func noteThread(_ name: String) {
    if Thread.isMainThread { mainThreadVaultCalls.withLock { $0.append(name) } }
  }

  func password(for endpoint: String) throws -> String? { entries.withLock { $0["password|\(endpoint)"] } }
  func setPassword(_ password: String, for endpoint: String) throws {
    entries.withLock { $0["password|\(endpoint)"] = password }
  }
  func deletePassword(for endpoint: String) throws {
    _ = entries.withLock { $0.removeValue(forKey: "password|\(endpoint)") }
  }
  func hasPassword(for endpoint: String) -> Bool { entries.withLock { $0["password|\(endpoint)"] != nil } }
  func passphrase(forKeyDigest digest: String) throws -> String? {
    entries.withLock { $0["passphrase|\(digest)"] }
  }
  func setPassphrase(_ passphrase: String, forKeyDigest digest: String) throws {
    entries.withLock { $0["passphrase|\(digest)"] = passphrase }
  }
  func deletePassphrase(forKeyDigest digest: String) throws {
    _ = entries.withLock { $0.removeValue(forKey: "passphrase|\(digest)") }
  }
  func vaultPrivateKey(id: UUID) throws -> String? {
    noteThread("vaultPrivateKey")
    return entries.withLock { $0["vault|\(id)"] }
  }
  func setVaultPrivateKey(_ privateKey: String, id: UUID, label: String) throws {
    noteThread("setVaultPrivateKey")
    if failsVaultWrites.withLock({ $0 }) { throw SSHCredentialStoreError.keychain(-25293) }
    entries.withLock { $0["vault|\(id)"] = privateKey }
  }
  func deleteVaultPrivateKey(id: UUID) throws {
    noteThread("deleteVaultPrivateKey")
    _ = entries.withLock { $0.removeValue(forKey: "vault|\(id)") }
  }
  func hasVaultPrivateKey(id: UUID) -> Bool {
    noteThread("hasVaultPrivateKey")
    return entries.withLock { $0["vault|\(id)"] != nil }
  }

  /// 保险库私钥条目数。
  var vaultCount: Int { entries.withLock { $0.keys.filter { $0.hasPrefix("vault|") }.count } }
}

/// 可编排的 `aster-ssh keys`：私钥文本 → 结果；加密私钥要求指定 passphrase。
final class FakeVaultKeyTool: SSHVaultKeyTooling {
  /// 一把可识别的私钥。
  struct Entry: Sendable {
    var material: SSHVaultKeyMaterial
    /// 非 nil 表示加密，需要这个 passphrase。
    var passphrase: String?
  }

  private let entries: [String: Entry]
  private let calls = OSAllocatedUnfairLock(initialState: [String]())
  private let generated: SSHVaultKeyMaterial?

  init(entries: [String: Entry] = [:], generated: SSHVaultKeyMaterial? = nil) {
    self.entries = entries
    self.generated = generated
  }

  /// 调用记录（"inspect" / "inspect+passphrase" / "generate"），不含秘密。
  var recordedCalls: [String] { calls.withLock { $0 } }

  func inspect(privateKey: String, passphrase: String?, comment: String?) async throws
    -> SSHVaultKeyMaterial
  {
    calls.withLock { $0.append(passphrase == nil ? "inspect" : "inspect+passphrase") }
    guard let entry = entries[privateKey] else { throw SSHVaultKeyToolError.invalid }
    if let expected = entry.passphrase {
      guard let passphrase else { throw SSHVaultKeyToolError.encrypted }
      guard passphrase == expected else { throw SSHVaultKeyToolError.wrongPassphrase }
    }
    return entry.material
  }

  func generate(comment: String) async throws -> SSHVaultKeyMaterial {
    calls.withLock { $0.append("generate") }
    guard var material = generated else { throw SSHVaultKeyToolError.unsupported }
    material.comment = comment
    return material
  }
}

/// 一份假的密钥材料。`seed` 决定公钥与指纹，便于构造不同的密钥。
func fakeVaultMaterial(_ seed: String, comment: String = "") -> SSHVaultKeyMaterial {
  let blob = Data("key-\(seed)".utf8).base64EncodedString()
  return SSHVaultKeyMaterial(
    privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n\(seed)\n-----END OPENSSH PRIVATE KEY-----\n",
    publicKey: comment.isEmpty ? "ssh-ed25519 \(blob)" : "ssh-ed25519 \(blob) \(comment)",
    algorithm: "ssh-ed25519", fingerprint: "SHA256:\(seed)", comment: comment)
}
