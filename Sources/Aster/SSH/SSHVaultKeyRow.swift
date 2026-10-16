import AsterCore
import Foundation

// 保险库里一把密钥的展示数据：公开元数据加上使用情况与状态标记。
// 由 `SSHVaultKeyActions.rows(hosts:)` 统一计算，「主机 → 密钥」页与设置页桥接的快照共用，
// 不在两处各算一遍。只含公开信息，没有私钥。

/// 一把保险库密钥的展示行。
struct SSHVaultKeyRow: Equatable, Identifiable {
  var key: SSHVaultKey
  /// 引用这把密钥的主机名（默认项显示为「默认」）。
  var usedBy: [String]
  /// `identityFiles` 仍指向原文件、可以改用这把保险库密钥的主机名。
  var migratableHosts: [String]
  /// 导入时的原文件是否仍在磁盘上；生成的密钥恒为 false。
  var originalExists: Bool
  /// 钥匙串里找不到私钥（读 `SSHVaultKeyDirectory.keychainMissing` 缓存）。
  var keychainMissing: Bool

  var id: UUID { key.id }

  /// 原文件路径，家目录缩写成 `~`；生成的密钥为 nil。
  var importedFromDisplay: String? {
    key.importedFrom.map { ($0 as NSString).abbreviatingWithTildeInPath }
  }

  /// 能否「删除原文件」：导入的密钥且原文件仍在。
  var canDeleteOriginal: Bool { key.origin == .imported && originalExists }

  /// 来源说明：「导入自 <路径>」「已导入」或「在 Aster 中生成」。
  var originText: String {
    switch key.origin {
    case .imported: importedFromDisplay.map { L("导入自 \($0)") } ?? L("已导入")
    case .generated: L("在 Aster 中生成")
    }
  }

  /// 短指纹：`SHA256:` 后取前 16 个字符，与网页版一致；完整值放在提示里。
  static func shortFingerprint(_ fingerprint: String) -> String {
    guard fingerprint.hasPrefix("SHA256:") else { return fingerprint }
    let body = fingerprint.dropFirst("SHA256:".count)
    return body.count > 16 ? "SHA256:\(body.prefix(16))…" : fingerprint
  }

  /// 搜索匹配：名称、算法、指纹、注释、原文件路径与使用它的主机名，不区分大小写；空查询全匹配。
  func matches(_ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    let fields = [key.label, key.algorithm, key.fingerprint, key.comment, importedFromDisplay ?? ""] + usedBy
    return fields.contains { $0.localizedCaseInsensitiveContains(needle) }
  }
}
