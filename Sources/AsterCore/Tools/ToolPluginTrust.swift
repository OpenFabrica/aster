// 插件信任：根据来源、授权记录与文件摘要判断能否直接运行，以及 WebKit 数据存储标识。目录摘要在 ToolPluginDigest.swift。
import CryptoKit
import Foundation

/// 插件当前能否运行。
public enum ToolPluginStatus: Equatable, Sendable {
  case ready
  /// 用户停用。
  case disabled
  /// 运行前需要用户确认。
  case needsApproval(ToolApprovalReason)
}

/// 为什么需要确认。
public enum ToolApprovalReason: Equatable, Sendable {
  /// 第一次运行（没有授权记录，或记录里从没确认过）。
  case firstRun
  /// 用户来源的插件文件与授权时不同，或摘要无法计算。
  case filesChanged
  /// 新版本多要了这些权限（按清单声明顺序）。
  case permissionsAdded([ToolPermission])
  /// 新版本多要了这些域名（按清单声明顺序）。
  case networkDomainsAdded([String])

  /// 设置页快照里的取值。
  public var identifier: String {
    switch self {
    case .firstRun: "firstRun"
    case .filesChanged: "filesChanged"
    case .permissionsAdded: "permissionsAdded"
    case .networkDomainsAdded: "networkDomainsAdded"
    }
  }
}

/// 信任判断的纯函数。规则见 docs/developer/tools-and-plugins.md「权限与信任」。
public enum ToolPluginTrust {
  /// 判断插件状态，按以下顺序：
  /// 1. 用户停用 → `disabled`（任何来源）；
  /// 2. 内置来源，或没声明任何权限 → `ready`；
  /// 3. 没有确认过的授权记录 → `needsApproval(.firstRun)`；
  /// 4. 声明的权限多于已授权 → `.permissionsAdded`；声明的域名多于已授权 → `.networkDomainsAdded`；
  /// 5. 用户来源：当前摘要缺失或与授权时不同 → `.filesChanged`（开发来源不比对摘要，方便热重载）。
  /// `currentDigest` 只对用户来源有意义，其他来源传 nil 即可。
  public static func status(
    manifest: ToolManifest,
    source: ToolPluginSource,
    state: ToolPluginState?,
    currentDigest: String?
  ) -> ToolPluginStatus {
    if let state, !state.enabled { return .disabled }
    if source == .builtin || manifest.permissions.isEmpty { return .ready }
    guard let state, state.hasApproval else { return .needsApproval(.firstRun) }
    let granted = Set(state.grantedPermissions)
    let missing = manifest.permissions.filter { !granted.contains($0) }
    if !missing.isEmpty { return .needsApproval(.permissionsAdded(missing)) }
    let grantedDomains = Set(state.grantedNetworkDomains.map { $0.lowercased() })
    let missingDomains = manifest.network.filter { !grantedDomains.contains($0.lowercased()) }
    if !missingDomains.isEmpty { return .needsApproval(.networkDomainsAdded(missingDomains)) }
    // 摘要算不出来时同样要求重新确认：无法证明文件没变，就不能沿用旧授权。
    if source == .user, currentDigest == nil || currentDigest != state.approvedDigest {
      return .needsApproval(.filesChanged)
    }
    return .ready
  }

  /// 用户同意后应写入的状态：授予清单声明的全部权限与域名（替换旧授权，不累加），记下摘要与版本，并启用。
  public static func approvedState(
    manifest: ToolManifest,
    digest: String?,
    previous: ToolPluginState?
  ) -> ToolPluginState {
    var state = previous ?? ToolPluginState()
    state.enabled = true
    state.grantedPermissions = manifest.permissions
    state.grantedNetworkDomains = manifest.network
    state.approvedDigest = digest
    state.approvedVersion = manifest.version
    return state
  }

  /// 实际生效的权限：内置来源为清单声明的全部；其他来源为「声明 ∩ 已授权」。
  /// 只决定能力范围，不代替 `status`：调用方仍须先确认插件是 `ready`。
  public static func effectivePermissions(
    manifest: ToolManifest,
    source: ToolPluginSource,
    state: ToolPluginState?
  ) -> Set<ToolPermission> {
    let declared = Set(manifest.permissions)
    guard source != .builtin else { return declared }
    return declared.intersection(state?.grantedPermissions ?? [])
  }

  /// 实际允许访问的域名：内置来源为清单声明的全部；其他来源为「声明 ∩ 已授权」（大小写无关），保持声明顺序。
  public static func effectiveNetworkDomains(
    manifest: ToolManifest,
    source: ToolPluginSource,
    state: ToolPluginState?
  ) -> [String] {
    guard source != .builtin else { return manifest.network }
    let granted = Set((state?.grantedNetworkDomains ?? []).map { $0.lowercased() })
    return manifest.network.filter { granted.contains($0.lowercased()) }
  }

  /// 安装确认要列出的权限：高风险排前，同级按声明顺序。
  public static func permissionsRequiringConsent(_ manifest: ToolManifest) -> [ToolPermission] {
    manifest.permissions.enumerated()
      .sorted { lhs, rhs in
        lhs.element.risk != rhs.element.risk ? lhs.element.risk > rhs.element.risk : lhs.offset < rhs.offset
      }
      .map(\.element)
  }
}

/// 插件身份派生值。
public enum ToolPluginIdentity {
  /// 由插件 id 稳定推导 `WKWebsiteDataStore(forIdentifier:)` 的标识：同一插件每次相同，不同插件互不相同。
  /// 取 SHA-256 前 16 字节并设置 UUID v5 风格的版本与变体位，避免与随机 UUID 混淆。
  public static func dataStoreIdentifier(pluginID: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data("aster-plugin-data-store:\(pluginID)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
