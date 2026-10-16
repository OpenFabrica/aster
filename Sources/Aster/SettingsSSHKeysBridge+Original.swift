import AsterCore
import Foundation

// 设置页密钥桥接的兼容入口：旧名字转到 `SSHVaultKeyActions`，供主机桥与既有测试继续使用。
// 「删除原私钥文件」的核对与删除已移到 SSHVaultKeyActions+Original.swift；网页设置页移除时一起删掉本文件。

/// 旧错误类型名，等同 `SSHVaultKeyActionError`。
typealias SettingsSSHKeysError = SSHVaultKeyActionError

extension SettingsSSHKeysBridge {
  /// 读取私钥文件；见 `SSHVaultKeyActions.readKeyFile`。
  nonisolated static func readKeyFile(_ url: URL) throws -> String {
    try SSHVaultKeyActions.readKeyFile(url)
  }

  /// 已解析软链的路径是否在 `~/.ssh` 里；见 `SSHVaultKeyActions.isInsideSSHDirectory`。
  nonisolated static func isInsideSSHDirectory(_ resolved: String, homeDirectory: String) -> Bool {
    SSHVaultKeyActions.isInsideSSHDirectory(resolved, homeDirectory: homeDirectory)
  }
}
