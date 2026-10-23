// 「一直允许」授权的钥匙串存储：一个 generic password 条目，值是授权数组的 JSON。
// 放钥匙串而不是 UserDefaults / 文件：agent 能改 defaults 和用户文件。但同一用户下的进程
// 可以新建同名条目（例如 `security add-generic-password -A`），所以读取前先核对条目 ACL：
// 解密项信任「任何 App」的条目一律拒绝（不删除），见 AgentHostKeychainAccessCheck。
// 剩余限制：用显式受信任列表建的条目（`security add-generic-password -T /Applications/Aster.app`）
// 与 Aster 自己用默认 ACL 建的无法区分；这一类预埋只能靠审计与设置页里的授权列表发现。
import AsterCore
import Foundation
import Security
import os

/// always 授权的持久化接口；测试换内存实现。
protocol AgentHostGrantPersisting: Sendable {
  /// 读出全部 always 授权；条目不存在返回空数组；条目不可信抛 `AgentHostGrantKeychainError.untrustedAccess`。
  func load() throws -> [AgentHostGrant]
  /// 覆盖写入；空数组删除条目。
  func save(_ grants: [AgentHostGrant]) throws
}

/// 钥匙串条目不可信（不是 Aster 用默认 ACL 建的）。条目保留不删，由调用方当作没有授权并记诊断。
enum AgentHostGrantKeychainError: Error, Sendable, Equatable {
  case untrustedAccess(String)
}

/// 钥匙串实现。读写都可能被 securityd 授权框卡住，调用方必须放后台。
struct AgentHostGrantKeychain: AgentHostGrantPersisting {
  static let service = "io.aster.agent-host-grants"
  static let account = "always"

  /// service 后缀。正式版为空；开发版是 `.dev`，和正式版各存一条（见 `AsterAppIdentity`）；
  /// 测试另传后缀，避免碰真实条目。
  var serviceSuffix = AsterAppIdentity.current.keychainServiceSuffix

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service + serviceSuffix,
      kSecAttrAccount as String: Self.account,
    ]
  }

  /// 读出 always 授权：先按引用核对条目 ACL，可信才读明文。
  ///
  /// 先核对再读数据：被预埋的条目可能带别的分区（partition），读明文会弹授权框；
  /// 只取引用与 ACL 不需要解密，不会弹框。
  func load() throws -> [AgentHostGrant] {
    guard let reference = try itemReference() else { return [] }
    if let reason = AgentHostKeychainAccessCheck.untrustedReason(try AgentHostKeychainAccessCheck.entries(of: reference)) {
      throw AgentHostGrantKeychainError.untrustedAccess(reason)
    }
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { throw SSHCredentialStoreError.keychain(errSecDecode) }
      return try Self.decoder.decode([AgentHostGrant].self, from: data)
    case errSecItemNotFound:
      return []
    default:
      throw SSHCredentialStoreError.keychain(status)
    }
  }

  /// 覆盖写入；空数组删除条目。已有条目不可信时删掉重建，不往预埋的条目里写。
  ///
  /// 新建时不带 `kSecAttrAccess`：默认 ACL 的解密项只信任创建它的 App（Aster 自身），
  /// 其它进程读取都要用户在授权框里确认，这正是 `load()` 核对的形态。
  func save(_ grants: [AgentHostGrant]) throws {
    guard !grants.isEmpty else {
      try deleteItem()
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: try Self.encoder.encode(grants),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    if let reference = try itemReference(),
      AgentHostKeychainAccessCheck.untrustedReason(try AgentHostKeychainAccessCheck.entries(of: reference)) != nil
    {
      // 更新不改 ACL：往预埋条目里写，下次读取照样被拒，用户的授权等于白给。删掉重建成默认 ACL。
      try deleteItem()
    }
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    switch update {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var item = query.merging(attributes) { _, new in new }
      item[kSecAttrLabel as String] = "Aster agent host grants"
      let add = SecItemAdd(item as CFDictionary, nil)
      guard add == errSecSuccess else { throw SSHCredentialStoreError.keychain(add) }
    default:
      throw SSHCredentialStoreError.keychain(update)
    }
  }

  /// 条目引用（不读明文）；不存在返回 nil。
  private func itemReference() throws -> CFTypeRef? {
    var request = query
    request[kSecReturnRef as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var reference: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &reference)
    switch status {
    case errSecSuccess: return reference
    case errSecItemNotFound: return nil
    default: throw SSHCredentialStoreError.keychain(status)
    }
  }

  /// 删除条目；本来就不存在不算错。
  private func deleteItem() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SSHCredentialStoreError.keychain(status)
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// 内存实现：测试与钥匙串不可用时的替身。
final class InMemoryAgentHostGrantPersistence: AgentHostGrantPersisting {
  private let stored: OSAllocatedUnfairLock<[AgentHostGrant]>

  init(_ grants: [AgentHostGrant] = []) { stored = OSAllocatedUnfairLock(initialState: grants) }

  func load() throws -> [AgentHostGrant] { stored.withLock { $0 } }

  func save(_ grants: [AgentHostGrant]) throws { stored.withLock { $0 = grants } }
}
