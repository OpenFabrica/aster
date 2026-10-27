// 插件信任状态机、授权写入、生效权限与域名、确认顺序，以及 WebKit 数据存储标识。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolPluginTrust")
struct ToolPluginTrustTests {
  /// 声明 exec + network（一个域名）的插件。
  private func manifest(
    permissions: [ToolPermission] = [.exec, .network],
    network: [String] = ["api.example.com"]
  ) -> ToolManifest {
    var manifest = ToolManifestFixture.manifest()
    manifest.permissions = permissions
    manifest.network = network
    return manifest
  }

  /// 便捷调用。
  private func status(
    _ manifest: ToolManifest,
    _ source: ToolPluginSource,
    _ state: ToolPluginState?,
    digest: String? = "d1"
  ) -> ToolPluginStatus {
    ToolPluginTrust.status(manifest: manifest, source: source, state: state, currentDigest: digest)
  }

  /// 内置来源与没声明权限的插件启用即可运行；用户停用对任何来源都生效。
  @Test func builtinAndPermissionlessAreReady() {
    #expect(status(manifest(), .builtin, nil) == .ready)
    #expect(status(manifest(permissions: [], network: []), .user, nil, digest: nil) == .ready)
    #expect(status(manifest(), .builtin, ToolPluginState(enabled: false)) == .disabled)
    #expect(status(manifest(), .user, ToolPluginState(enabled: false)) == .disabled)
  }

  /// 没有记录，或记录里只有启用开关（从没确认过）都算第一次运行。
  @Test func firstRunWithoutApproval() {
    #expect(status(manifest(), .user, nil) == .needsApproval(.firstRun))
    #expect(status(manifest(), .development, ToolPluginState(enabled: true)) == .needsApproval(.firstRun))
  }

  /// 同意后用户来源与开发来源都可运行。
  @Test func approvedPluginIsReady() {
    let approved = ToolPluginTrust.approvedState(manifest: manifest(), digest: "d1", previous: nil)
    #expect(approved.enabled)
    #expect(approved.grantedPermissions == [.exec, .network])
    #expect(approved.grantedNetworkDomains == ["api.example.com"])
    #expect(approved.approvedVersion == "1.2.0")
    #expect(approved.hasApproval)
    #expect(status(manifest(), .user, approved) == .ready)
    #expect(status(manifest(), .development, approved, digest: nil) == .ready)
  }

  /// 新版本多要权限或域名时要求重新确认，并列出新增项；权限优先于域名报告。
  @Test func addedPermissionsAndDomains() {
    let approved = ToolPluginTrust.approvedState(manifest: manifest(), digest: "d1", previous: nil)
    let morePermissions = manifest(permissions: [.notify, .exec, .network, .clipboardRead])
    #expect(status(morePermissions, .user, approved) == .needsApproval(.permissionsAdded([.notify, .clipboardRead])))
    let moreDomains = manifest(network: ["API.example.com", "cdn.example.com"])
    #expect(status(moreDomains, .user, approved) == .needsApproval(.networkDomainsAdded(["cdn.example.com"])))
    let both = manifest(permissions: [.exec, .network, .notify], network: ["cdn.example.com"])
    #expect(status(both, .user, approved) == .needsApproval(.permissionsAdded([.notify])))
    #expect(status(manifest(permissions: [.exec], network: []), .user, approved) == .ready)
  }

  /// 用户来源比对摘要（不同或算不出来都要重新确认），开发来源不比对。
  @Test func digestOnlyMattersForUserSource() {
    let approved = ToolPluginTrust.approvedState(manifest: manifest(), digest: "d1", previous: nil)
    #expect(status(manifest(), .user, approved, digest: "d2") == .needsApproval(.filesChanged))
    #expect(status(manifest(), .user, approved, digest: nil) == .needsApproval(.filesChanged))
    #expect(status(manifest(), .development, approved, digest: "d2") == .ready)
    let noDigest = ToolPluginTrust.approvedState(manifest: manifest(), digest: nil, previous: nil)
    #expect(status(manifest(), .user, noDigest, digest: nil) == .needsApproval(.filesChanged))
  }

  /// 再次同意替换旧授权（不累加）并重新启用；原因标识与设置页快照一致。
  @Test func reapprovalReplacesGrants() {
    let previous = ToolPluginState(enabled: false, grantedPermissions: [.notify], grantedNetworkDomains: ["old.com"])
    let state = ToolPluginTrust.approvedState(manifest: manifest(permissions: [.exec], network: []), digest: "d", previous: previous)
    #expect(state.enabled)
    #expect(state.grantedPermissions == [.exec])
    #expect(state.grantedNetworkDomains.isEmpty)
    #expect(ToolApprovalReason.firstRun.identifier == "firstRun")
    #expect(ToolApprovalReason.filesChanged.identifier == "filesChanged")
    #expect(ToolApprovalReason.permissionsAdded([]).identifier == "permissionsAdded")
    #expect(ToolApprovalReason.networkDomainsAdded([]).identifier == "networkDomainsAdded")
  }

  /// 生效权限与域名：内置为声明的全部，其他来源为「声明 ∩ 已授权」。
  @Test func effectiveGrants() {
    let declared = manifest(permissions: [.exec, .network, .notify], network: ["a.com", "B.com"])
    let state = ToolPluginState(grantedPermissions: [.exec, .clipboardRead], grantedNetworkDomains: ["b.com", "c.com"])
    #expect(ToolPluginTrust.effectivePermissions(manifest: declared, source: .builtin, state: nil) == [.exec, .network, .notify])
    #expect(ToolPluginTrust.effectivePermissions(manifest: declared, source: .user, state: state) == [.exec])
    #expect(ToolPluginTrust.effectivePermissions(manifest: declared, source: .user, state: nil).isEmpty)
    #expect(ToolPluginTrust.effectiveNetworkDomains(manifest: declared, source: .development, state: state) == ["B.com"])
    #expect(ToolPluginTrust.effectiveNetworkDomains(manifest: declared, source: .builtin, state: nil) == ["a.com", "B.com"])
  }

  /// 安装确认的权限顺序：高风险在前，同级保持声明顺序。
  @Test func consentOrdering() {
    let declared = manifest(permissions: [.notify, .filesRead, .exec, .clipboardWrite, .network], network: ["a.com"])
    #expect(ToolPluginTrust.permissionsRequiringConsent(declared) == [.exec, .filesRead, .network, .notify, .clipboardWrite])
  }

  /// 数据存储标识：同一插件稳定、不同插件不同，带版本 5 与 RFC 4122 变体位。
  @Test func dataStoreIdentifierIsStableAndDistinct() {
    let ids = ["com.a.b", "com.a.c", "aster.builtin", "com.a.b-", "com.a.bb"]
    let identifiers = ids.map(ToolPluginIdentity.dataStoreIdentifier(pluginID:))
    #expect(Set(identifiers).count == ids.count)
    #expect(ToolPluginIdentity.dataStoreIdentifier(pluginID: "com.a.b") == identifiers[0])
    for identifier in identifiers {
      let bytes = identifier.uuid
      #expect(bytes.6 >> 4 == 5)
      #expect(bytes.8 >> 6 == 0b10)
    }
  }
}
