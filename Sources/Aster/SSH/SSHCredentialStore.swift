import AsterCore
import Foundation
import Security

// SSH 凭证的钥匙串存取。
// 口令：service `io.aster.ssh`，账户 `user@host:port`；
// 私钥 passphrase：service `io.aster.ssh-key`，账户是私钥文件内容 SHA-512 的小写 hex；
// 保险库私钥：service `io.aster.ssh-vault`，账户是 `SSHVaultKey.id`，内容是未加密的 OpenSSH 私钥文本
// （钥匙串本身负责静态加密，再套一层 passphrase 只会多一个同 ACL 的秘密）。
// 秘密只进钥匙串，永不写文件或日志；错误只带 OSStatus，不带账户或秘密。

/// 钥匙串访问失败。
enum SSHCredentialStoreError: Error, Equatable {
  case keychain(OSStatus)
}

/// 凭证存储的抽象，便于认证协调者在测试里换成内存实现。
///
/// 要求 `Sendable`：协调者把钥匙串调用放到后台任务执行，避免 securityd 弹授权框时卡住主线程。
protocol SSHCredentialStoring: Sendable {
  /// 读取口令；不存在返回 nil。
  func password(for endpoint: String) throws -> String?
  /// 保存口令（覆盖已有值）。
  func setPassword(_ password: String, for endpoint: String) throws
  /// 删除口令；不存在不算错误。
  func deletePassword(for endpoint: String) throws
  /// 是否已保存口令。
  func hasPassword(for endpoint: String) -> Bool
  /// 读取私钥 passphrase；不存在返回 nil。
  func passphrase(forKeyDigest digest: String) throws -> String?
  /// 保存私钥 passphrase（覆盖已有值）。
  func setPassphrase(_ passphrase: String, forKeyDigest digest: String) throws
  /// 删除私钥 passphrase；不存在不算错误。
  func deletePassphrase(forKeyDigest digest: String) throws
  /// 读取保险库私钥（未加密 OpenSSH 文本）；不存在返回 nil。
  func vaultPrivateKey(id: UUID) throws -> String?
  /// 保存保险库私钥（覆盖已有值）；`label` 是钥匙串访问里显示的名称。
  func setVaultPrivateKey(_ privateKey: String, id: UUID, label: String) throws
  /// 删除保险库私钥；不存在不算错误。
  func deleteVaultPrivateKey(id: UUID) throws
  /// 是否存在保险库私钥条目。只查属性不取数据，不会触发授权框。
  func hasVaultPrivateKey(id: UUID) -> Bool
}

/// SSH 凭证存储：macOS 钥匙串里的 generic password 条目。
///
/// 用登录钥匙串（文件型）而不是 data protection 钥匙串：后者要求 keychain-access-groups
/// entitlement，而 Aster 的签名不带任何 entitlements。条目的 ACL 信任创建它的已签名 App，
/// 换签名身份后系统会询问一次。
struct SSHCredentialStore: SSHCredentialStoring {
  static let passwordService = "io.aster.ssh"
  static let passphraseService = "io.aster.ssh-key"
  static let vaultService = "io.aster.ssh-vault"

  /// 测试用后缀，避免污染真实条目；生产为空。
  var serviceSuffix: String

  init(serviceSuffix: String = "") { self.serviceSuffix = serviceSuffix }

  /// 读取某个 endpoint 的口令；不存在返回 nil。
  func password(for endpoint: String) throws -> String? {
    try read(service: Self.passwordService, account: endpoint)
  }

  /// 保存口令（覆盖已有值）。
  func setPassword(_ password: String, for endpoint: String) throws {
    try write(
      password, service: Self.passwordService, account: endpoint,
      label: "Aster SSH: \(endpoint)")
  }

  /// 删除口令；不存在不算错误。
  func deletePassword(for endpoint: String) throws {
    try delete(service: Self.passwordService, account: endpoint)
  }

  /// 是否已保存口令（设置页显示「忘记口令」用）。
  ///
  /// 只查属性不取数据：不读秘密就不会触发 ACL 授权框，适合在主线程上刷新界面。
  /// 查询失败（钥匙串锁定等）按「没有」显示。
  func hasPassword(for endpoint: String) -> Bool {
    exists(service: Self.passwordService, account: endpoint)
  }

  /// 读取私钥 passphrase。
  func passphrase(forKeyDigest digest: String) throws -> String? {
    try read(service: Self.passphraseService, account: digest)
  }

  /// 保存私钥 passphrase。
  func setPassphrase(_ passphrase: String, forKeyDigest digest: String) throws {
    try write(
      passphrase, service: Self.passphraseService, account: digest,
      label: "Aster SSH key passphrase")
  }

  /// 删除私钥 passphrase。
  func deletePassphrase(forKeyDigest digest: String) throws {
    try delete(service: Self.passphraseService, account: digest)
  }

  // MARK: - 保险库私钥

  /// 读取保险库私钥。调用方拿到后尽快交出并丢弃：Swift `String` 无法清零。
  func vaultPrivateKey(id: UUID) throws -> String? {
    try read(service: Self.vaultService, account: id.uuidString)
  }

  /// 保存保险库私钥。
  func setVaultPrivateKey(_ privateKey: String, id: UUID, label: String) throws {
    try write(
      privateKey, service: Self.vaultService, account: id.uuidString,
      label: "Aster SSH key: \(label)")
  }

  /// 删除保险库私钥。
  func deleteVaultPrivateKey(id: UUID) throws {
    try delete(service: Self.vaultService, account: id.uuidString)
  }

  /// 保险库私钥条目是否存在（设置页「钥匙串中缺失」标记用）。
  func hasVaultPrivateKey(id: UUID) -> Bool {
    exists(service: Self.vaultService, account: id.uuidString)
  }

  // MARK: - 钥匙串原语

  /// 只查属性判断条目是否存在：不读秘密就不会触发 ACL 授权框，适合在主线程上刷新界面。
  /// 查询失败（钥匙串锁定等）按「没有」处理。
  private func exists(service: String, account: String) -> Bool {
    var query = baseQuery(service: service, account: account)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  /// 定位一条条目的最小查询：类别 + service + account。
  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service + serviceSuffix,
      kSecAttrAccount as String: account,
    ]
  }

  /// 读出秘密；条目不存在返回 nil，其它失败抛出 OSStatus。
  private func read(service: String, account: String) throws -> String? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
        throw SSHCredentialStoreError.keychain(errSecDecode)
      }
      return secret
    case errSecItemNotFound:
      return nil
    default:
      throw SSHCredentialStoreError.keychain(status)
    }
  }

  /// 覆盖写入：先 update，没有条目再 add。
  ///
  /// add 遇到 `errSecDuplicateItem` 说明别的线程抢先建了条目，再 update 一次即可。
  private func write(_ secret: String, service: String, account: String, label: String) throws {
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(secret.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var item = query.merging(attributes) { _, new in new }
      item[kSecAttrLabel as String] = label
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      if addStatus == errSecDuplicateItem {
        let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard retryStatus == errSecSuccess else { throw SSHCredentialStoreError.keychain(retryStatus) }
        return
      }
      guard addStatus == errSecSuccess else { throw SSHCredentialStoreError.keychain(addStatus) }
    default:
      throw SSHCredentialStoreError.keychain(updateStatus)
    }
  }

  /// 删除条目；不存在不算错误。
  private func delete(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SSHCredentialStoreError.keychain(status)
    }
  }
}
