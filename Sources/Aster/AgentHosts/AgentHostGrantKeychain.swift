// 「一直允许」授权的钥匙串存储：一个 generic password 条目，值是授权数组的 JSON。
// 放钥匙串而不是 UserDefaults / 文件：agent 能改 defaults 和用户文件，却不能静默改钥匙串
// 条目（ACL 信任的是签名的 App），也就没法给自己加授权。
import AsterCore
import Foundation
import Security
import os

/// always 授权的持久化接口；测试换内存实现。
protocol AgentHostGrantPersisting: Sendable {
  /// 读出全部 always 授权；条目不存在返回空数组。
  func load() throws -> [AgentHostGrant]
  /// 覆盖写入；空数组删除条目。
  func save(_ grants: [AgentHostGrant]) throws
}

/// 钥匙串实现。读写都可能被 securityd 授权框卡住，调用方必须放后台。
struct AgentHostGrantKeychain: AgentHostGrantPersisting {
  static let service = "io.aster.agent-host-grants"
  static let account = "always"

  /// 测试用后缀，避免碰真实条目；生产为空。
  var serviceSuffix = ""

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service + serviceSuffix,
      kSecAttrAccount as String: Self.account,
    ]
  }

  func load() throws -> [AgentHostGrant] {
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

  func save(_ grants: [AgentHostGrant]) throws {
    guard !grants.isEmpty else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw SSHCredentialStoreError.keychain(status)
      }
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: try Self.encoder.encode(grants),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
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
