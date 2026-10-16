// 钥匙串条目 ACL 的核对：拒绝「任何 App 都能读」的条目，防止别的进程替 agent 预埋「一直允许」授权。
// 判定逻辑是纯函数（可单测）；读取 ACL 用的是已弃用的 SecKeychain* / SecACL* API，单独包在下面。
import Foundation
import Security

/// 钥匙串条目访问控制的核对。
enum AgentHostKeychainAccessCheck {
  /// 一条 ACL 的摘要：授权的操作，以及受信任 App 列表是否为 nil（= 任何 App 都不经询问放行）。
  struct Entry: Equatable, Sendable {
    var authorizations: [String]
    var trustsAnyApplication: Bool
  }

  /// 读不读得到明文的那两种授权：解密，或「任意操作」。
  /// 值取自 SDK 常量 `kSecACLAuthorizationDecrypt` / `kSecACLAuthorizationAny`（未弃用）。
  static let decryptAuthorizations: Set<String> = [
    kSecACLAuthorizationDecrypt as String, kSecACLAuthorizationAny as String,
  ]

  /// 条目不可信时返回原因，可信返回 nil。
  ///
  /// 只要有一条授权解密的 ACL 信任任何 App，就说明条目不是 Aster 用默认 ACL 建的
  /// （默认 ACL 的解密项只信任创建它的 App），可能是别的进程用 `security -A` 之类预埋的。
  /// 没有任何 ACL 时语义不明，保守地当作不可信。
  static func untrustedReason(_ entries: [Entry]) -> String? {
    guard !entries.isEmpty else { return "条目没有 ACL" }
    for entry in entries where entry.trustsAnyApplication {
      if !decryptAuthorizations.isDisjoint(with: entry.authorizations) {
        return "条目允许任何 App 不经询问读取（\(entry.authorizations.joined(separator: ","))）"
      }
    }
    return nil
  }

  /// 读出 `SecItemCopyMatching(kSecReturnRef)` 返回的条目引用上的全部 ACL。
  ///
  /// 引用不是文件钥匙串条目（例如落在 data protection 钥匙串）时无法核对，按不可信处理。
  static func entries(of itemReference: CFTypeRef) throws -> [Entry] {
    try (LegacyACLReader() as any ACLReading).entries(of: itemReference)
  }
}

/// ACL 读取的抽象：只为把弃用 API 关进一个实现里。
private protocol ACLReading {
  func entries(of itemReference: CFTypeRef) throws -> [AgentHostKeychainAccessCheck.Entry]
}

/// 用 SecKeychain 系列 API 读 ACL。
///
/// 为什么用弃用 API：macOS 文件钥匙串（SecItemAdd 不带 data protection 时的落点）的 ACL 只有
/// SecKeychainItemCopyAccess / SecAccessCopyACLList / SecACLCopyContents 能读，没有非弃用替代；
/// 这些函数在 macOS 14 SDK 里仍然可用。方法标 `@available(deprecated:)` 并经协议调用，
/// 弃用告警就只留在这一处声明上，不扩散到调用方。
private struct LegacyACLReader: ACLReading {
  /// 逐条取 ACL 的授权列表与受信任 App 列表。
  @available(macOS, deprecated: 10.10, message: "文件钥匙串 ACL 只能经 SecKeychain API 读取")
  func entries(of itemReference: CFTypeRef) throws -> [AgentHostKeychainAccessCheck.Entry] {
    guard CFGetTypeID(itemReference) == SecKeychainItemGetTypeID() else {
      throw AgentHostGrantKeychainError.untrustedAccess("条目不在文件钥匙串里，无法核对 ACL")
    }
    // 类型已按 CFTypeID 核对，强转不会失败。
    let item = itemReference as! SecKeychainItem
    var access: SecAccess?
    let accessStatus = SecKeychainItemCopyAccess(item, &access)
    guard accessStatus == errSecSuccess, let access else { throw SSHCredentialStoreError.keychain(accessStatus) }
    var list: CFArray?
    let listStatus = SecAccessCopyACLList(access, &list)
    guard listStatus == errSecSuccess, let acls = list as? [SecACL] else {
      throw SSHCredentialStoreError.keychain(listStatus)
    }
    return try acls.map { acl in
      var applications: CFArray?
      var description: CFString?
      var prompt = SecKeychainPromptSelector()
      let status = SecACLCopyContents(acl, &applications, &description, &prompt)
      guard status == errSecSuccess else { throw SSHCredentialStoreError.keychain(status) }
      return .init(
        authorizations: SecACLCopyAuthorizations(acl) as? [String] ?? [],
        // 受信任 App 列表为 nil 表示任何 App 都放行；空数组表示谁都要询问。
        trustsAnyApplication: applications == nil)
    }
  }
}
