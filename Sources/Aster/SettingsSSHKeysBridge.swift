import AppKit
import AsterCore
import Foundation

// 设置页「主机 › 密钥」子页的桥接：把保险库展示行转成网页快照，并把 `hosts.keys.` 前缀的动作
// 转给 `SSHVaultKeyActions`。校验、错误文案与安全规则都在那个服务里，这里只做 JSON 适配。
//
// 由 `SettingsHostsBridge` 持有并转发动作；推送快照、toast、取窗口沿用它注入的闭包。
// 私钥与 passphrase 从不经过 WKWebView。保险库真值只在 `SSHVaultKeyDirectory`。

/// 「密钥」子页的快照与动作转发。
@MainActor
final class SettingsSSHKeysBridge {
  /// 依赖与原生页共用一份定义。
  typealias Dependencies = SSHVaultKeyActions.Dependencies

  /// 真正执行动作的服务。
  let actions: SSHVaultKeyActions
  var dependencies: Dependencies { actions.dependencies }
  var directory: SSHVaultKeyDirectory { actions.directory }

  /// 立即推送一份新快照。
  var pushSnapshot: () -> Void = {}
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }
  /// 设置窗口，用作打开面板与确认框的宿主。
  var window: () -> NSWindow? = { nil }
  /// 有动作在进行。网页的回执 5 秒就超时，按钮会提前恢复，连点时靠服务的互斥只跑一次。
  var isBusy: Bool { actions.isBusy }

  /// 建服务并把它的反馈转回本桥接的闭包（这些闭包在构造之后才由主机桥设置）。
  init(dependencies: Dependencies, hosts: SSHHostDirectory) {
    actions = SSHVaultKeyActions(dependencies: dependencies, hosts: hosts)
    actions.onChange = { [weak self] in self?.pushSnapshot() }
    actions.toast = { [weak self] text, isError in self?.toast(text, isError) }
    actions.window = { [weak self] in self?.window() ?? nil }
  }

  // MARK: - 快照

  /// 合并进主机快照的字段：`vaultKeys`、`vaultKeysError`、`sshEngine`。
  ///
  /// `vaultKeys` 每项：id、label、algorithm、fingerprint、publicKey、comment、createdAt（ISO 8601）、
  /// origin、importedFrom（缩写成 ~）、usedBy（引用它的主机名）、migratableHosts（`identityFiles`
  /// 仍指向原文件的主机名）、originalExists、keychainMissing。
  func snapshot(hosts: [SSHHostProfile]) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    let rows: [[String: Any]] = actions.rows(hosts: hosts).map { row in
      var item: [String: Any] = [
        "id": row.key.id.uuidString,
        "label": row.key.label,
        "algorithm": row.key.algorithm,
        "fingerprint": row.key.fingerprint,
        "publicKey": row.key.publicKey,
        "comment": row.key.comment,
        "createdAt": formatter.string(from: row.key.createdAt),
        "origin": row.key.origin.rawValue,
        "usedBy": row.usedBy,
        "migratableHosts": row.migratableHosts,
        "originalExists": row.originalExists,
        "keychainMissing": row.keychainMissing,
      ]
      item["importedFrom"] = row.importedFromDisplay
      return item
    }
    return [
      "vaultKeys": rows,
      "vaultKeysError": directory.loadError ?? "",
      "sshEngine": dependencies.engine().rawValue,
    ]
  }
}
