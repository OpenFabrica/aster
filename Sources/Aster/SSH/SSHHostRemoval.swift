import AsterCore
import Foundation

// 删除已保存主机的共用规则：侧栏主机页走这里，口令清理只有一份实现。

/// 删除一台主机，并在安全时顺带清掉钥匙串里的口令。
@MainActor
enum SSHHostRemoval {
  /// 删除主机。只有没有其它主机共用同一 endpoint 时，才删除钥匙串里的口令。
  ///
  /// - Returns: 主机已删除但口令没能删掉时返回该错误；nil 表示全部完成。
  /// - Throws: 主机本身删除失败（hosts.json 写入失败等），此时口令不动。
  static func remove(
    _ id: UUID, from directory: SSHHostDirectory, passwords: any SSHHostPasswordStore
  ) throws -> (any Error)? {
    let hosts = directory.hosts
    // 删除之前算：删完就解析不到它的 endpoint 了。
    let endpoint = SSHHostResolver.resolveAll(hosts).specs[id]?.credentialEndpoint
    let sharing = SSHHostStore.hostsSharingCredential(with: id, in: hosts)
    try directory.remove(id)
    guard let endpoint, sharing.isEmpty, passwords.hasPassword(for: endpoint) else { return nil }
    do {
      try passwords.deletePassword(for: endpoint)
      return nil
    } catch {
      return error
    }
  }
}
