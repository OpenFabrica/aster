// 「一直允许」授权钥匙串条目的 ACL 核对：纯判定逻辑，以及用测试专用服务名的真实钥匙串往返。
import AsterCore
import Foundation
import Security
import Testing

@testable import Aster

@Suite("agent 主机授权钥匙串 ACL 核对")
struct AgentHostGrantKeychainTests {
  private typealias Entry = AgentHostKeychainAccessCheck.Entry
  private let decrypt = kSecACLAuthorizationDecrypt as String

  @Test("默认 ACL：解密项只信任创建者，其余信任任何 App 的项不涉及解密 → 可信")
  func defaultACLIsTrusted() {
    let entries = [
      Entry(authorizations: [kSecACLAuthorizationEncrypt as String], trustsAnyApplication: true),
      Entry(authorizations: [decrypt, "ACLAuthorizationExportClear"], trustsAnyApplication: false),
      Entry(authorizations: ["ACLAuthorizationIntegrity"], trustsAnyApplication: true),
      Entry(authorizations: ["ACLAuthorizationChangeACL"], trustsAnyApplication: false),
    ]
    #expect(AgentHostKeychainAccessCheck.untrustedReason(entries) == nil)
  }

  @Test("解密项或 Any 项信任任何 App → 不可信；没有 ACL 也不可信")
  func openACLIsRejected() {
    #expect(AgentHostKeychainAccessCheck.untrustedReason([Entry(authorizations: [decrypt], trustsAnyApplication: true)]) != nil)
    #expect(
      AgentHostKeychainAccessCheck.untrustedReason([
        Entry(authorizations: [kSecACLAuthorizationAny as String], trustsAnyApplication: true)
      ]) != nil)
    #expect(AgentHostKeychainAccessCheck.untrustedReason([]) != nil)
  }

  @Test("真实钥匙串：Aster 写的条目读回；`security -A` 预埋的条目被拒且不删，再次保存时重建")
  func keychainRoundTrip() throws {
    let keychain = AgentHostGrantKeychain(serviceSuffix: ".test.\(UUID().uuidString)")
    defer { try? keychain.save([]) }
    let grant = AgentHostGrant(
      hostID: UUID(), scope: .always, sessionKey: nil, targetFingerprint: "f", grantedAt: Date(timeIntervalSince1970: 0),
      grantedBy: "tester")
    try keychain.save([grant])
    #expect(try keychain.load().map(\.grantID) == [grant.grantID])
    try keychain.save([])
    #expect(try keychain.load().isEmpty)

    // 模拟别的进程预埋一个任何 App 都能读的同名条目。
    let planted = Data(#"[{"grantID":"\#(UUID().uuidString)"}]"#.utf8).base64EncodedString()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = [
      "add-generic-password", "-A", "-s", AgentHostGrantKeychain.service + keychain.serviceSuffix,
      "-a", AgentHostGrantKeychain.account, "-w", planted,
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect {
      try keychain.load()
    } throws: { error in
      if case AgentHostGrantKeychainError.untrustedAccess = error { return true }
      return false
    }
    // 拒绝不删除：再读一次仍然是同一个结论。
    #expect(throws: AgentHostGrantKeychainError.self) { try keychain.load() }
    // Aster 自己再写一次：删掉预埋条目，按默认 ACL 重建，之后能正常读回。
    try keychain.save([grant])
    #expect(try keychain.load().map(\.grantID) == [grant.grantID])
  }
}
