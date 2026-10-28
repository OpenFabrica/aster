// 网页工具加密存储的密钥：每个插件一把 256 位对称密钥，存钥匙串 generic password（account 是插件 id）。
// 和「一直允许」授权一样先核对条目 ACL：别的进程能预埋同名条目（`security add-generic-password -A`），
// 用这种条目里的密钥加密，等于把明文交给预埋者。不可信的条目删掉重建，见 AgentHostKeychainAccessCheck。
import AsterCore
import Foundation
import Security
import os

/// 加密存储密钥的读写；测试换内存实现，不碰真实钥匙串。实现可能被授权框卡住，只能在后台调用。
protocol ToolSecureStorageKeyStoring: Sendable {
  /// 读插件的密钥；条目不存在返回 nil；条目不可信抛 `ToolSecureStorageKeyError.untrustedAccess`。
  func loadKey(pluginID: String) throws -> Data?
  /// 写入（覆盖）插件的密钥。
  func saveKey(_ key: Data, pluginID: String) throws
  /// 删除插件的密钥；本来就没有不算错。
  func deleteKey(pluginID: String) throws
}

/// 密钥读写失败。
enum ToolSecureStorageKeyError: Error, Equatable, Sendable {
  /// 条目不是 Aster 用默认 ACL 建的。
  case untrustedAccess(String)
  /// 钥匙串调用返回的错误码。
  case keychain(OSStatus)
}

/// 钥匙串实现。
struct ToolSecureStorageKeychain: ToolSecureStorageKeyStoring {
  static let service = "io.aster.tool-secure-storage"

  /// service 后缀：正式版为空，开发版 `.dev`（见 `AsterAppIdentity`）；测试另传，避免碰真实条目。
  var serviceSuffix = AsterAppIdentity.current.keychainServiceSuffix

  /// 按插件 id 定位条目的查询。
  private func query(pluginID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service + serviceSuffix,
      kSecAttrAccount as String: pluginID,
    ]
  }

  /// 先按引用核对 ACL（不解密、不弹框），可信才读出密钥。
  func loadKey(pluginID: String) throws -> Data? {
    guard let reference = try itemReference(pluginID: pluginID) else { return nil }
    if let reason = AgentHostKeychainAccessCheck.untrustedReason(try AgentHostKeychainAccessCheck.entries(of: reference)) {
      throw ToolSecureStorageKeyError.untrustedAccess(reason)
    }
    var request = query(pluginID: pluginID)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { throw ToolSecureStorageKeyError.keychain(errSecDecode) }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw ToolSecureStorageKeyError.keychain(status)
    }
  }

  /// 先删再建：新条目不带 `kSecAttrAccess`，默认 ACL 只信任 Aster 自身，也顺带清掉预埋条目的 ACL。
  func saveKey(_ key: Data, pluginID: String) throws {
    try deleteKey(pluginID: pluginID)
    var item = query(pluginID: pluginID)
    item[kSecValueData as String] = key
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    item[kSecAttrLabel as String] = "Aster tool storage key (\(pluginID))"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw ToolSecureStorageKeyError.keychain(status) }
  }

  /// 删除条目；不存在不算错。
  func deleteKey(pluginID: String) throws {
    let status = SecItemDelete(query(pluginID: pluginID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ToolSecureStorageKeyError.keychain(status)
    }
  }

  /// 条目引用（不读明文）；不存在返回 nil。
  private func itemReference(pluginID: String) throws -> CFTypeRef? {
    var request = query(pluginID: pluginID)
    request[kSecReturnRef as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var reference: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &reference)
    switch status {
    case errSecSuccess: return reference
    case errSecItemNotFound: return nil
    default: throw ToolSecureStorageKeyError.keychain(status)
    }
  }
}

/// 内存实现：测试用。`untrustedPluginIDs` 里的插件读取时模拟「条目不可信」。
final class InMemoryToolSecureStorageKeyStore: ToolSecureStorageKeyStoring {
  private struct State {
    var keys: [String: Data] = [:]
    var untrustedPluginIDs: Set<String> = []
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// 当前保存的密钥（测试断言用）。
  var keys: [String: Data] { state.withLock { $0.keys } }

  /// 模拟一个被预埋的不可信条目。
  func plantUntrustedKey(_ key: Data, pluginID: String) {
    state.withLock {
      $0.keys[pluginID] = key
      $0.untrustedPluginIDs.insert(pluginID)
    }
  }

  func loadKey(pluginID: String) throws -> Data? {
    try state.withLock { state in
      if state.untrustedPluginIDs.contains(pluginID) { throw ToolSecureStorageKeyError.untrustedAccess("any app") }
      return state.keys[pluginID]
    }
  }

  func saveKey(_ key: Data, pluginID: String) throws {
    state.withLock {
      $0.keys[pluginID] = key
      $0.untrustedPluginIDs.remove(pluginID)
    }
  }

  func deleteKey(pluginID: String) throws {
    state.withLock {
      $0.keys[pluginID] = nil
      $0.untrustedPluginIDs.remove(pluginID)
    }
  }
}
