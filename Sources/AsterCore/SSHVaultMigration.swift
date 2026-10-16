import Foundation

// 私钥保险库与主机配置之间的引用改写：导入私钥文件后把主机里指向该文件的 `identityFiles`
// 换成保险库引用，删除保险库密钥时清掉主机里的引用。纯函数，不读写文件也不碰钥匙串，
// 只有路径规范化（解析软链）通过注入的闭包访问文件系统。

/// 保险库引用迁移规则。
public enum SSHVaultMigration {
  /// 把路径规范化成可比较的形式：标准化并解析软链（`~/.ssh/id_ed25519` 可能是指向 dotfiles 的链接）。
  public static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// `identityFiles` 里指向 `path` 的主机 ID（含默认项），按列表顺序。
  ///
  /// 每条模板先按该主机的 host / user 展开 `%h`、`%r`、`~`，再与目标路径做规范化比较。
  /// 默认项没有具体主机，带 `%h` / `%r` 的模板无法确定指向哪个文件，跳过。
  public static func hostsReferencing(
    path: String,
    in hosts: [SSHHostProfile],
    homeDirectory: String = NSHomeDirectory(),
    localUser: String = NSUserName(),
    canonicalize: (String) -> String = canonicalPath
  ) -> [UUID] {
    let target = canonicalize(path)
    let defaults = hosts.first(where: \.isDefaults) ?? .emptyDefaults()
    return hosts.filter { profile in
      matchingIndices(
        in: profile, target: target, defaults: defaults, homeDirectory: homeDirectory,
        localUser: localUser, canonicalize: canonicalize
      ).isEmpty == false
    }.map(\.id)
  }

  /// 把指向 `path` 的 `identityFiles` 条目换成保险库密钥 `id`，返回新列表与改动的主机 ID。
  ///
  /// 原来继承默认项保险库密钥的主机，会先把默认项的列表抄过来再追加，保证迁移前后实际
  /// 尝试的密钥集合不变（只是私钥改由钥匙串提供）。
  public static func migratingReferences(
    path: String,
    to id: UUID,
    in hosts: [SSHHostProfile],
    homeDirectory: String = NSHomeDirectory(),
    localUser: String = NSUserName(),
    canonicalize: (String) -> String = canonicalPath
  ) -> (hosts: [SSHHostProfile], changed: [UUID]) {
    let target = canonicalize(path)
    let defaults = hosts.first(where: \.isDefaults) ?? .emptyDefaults()
    var changed: [UUID] = []
    let next = hosts.map { profile -> SSHHostProfile in
      let indices = matchingIndices(
        in: profile, target: target, defaults: defaults, homeDirectory: homeDirectory,
        localUser: localUser, canonicalize: canonicalize)
      guard !indices.isEmpty else { return profile }
      var copy = profile
      copy.identityFiles = profile.identityFiles.enumerated()
        .filter { !indices.contains($0.offset) }.map(\.element)
      let inherited = profile.isDefaults ? [] : (defaults.vaultKeyIDs ?? [])
      var ids = profile.vaultKeyIDs?.isEmpty == false ? profile.vaultKeyIDs ?? [] : inherited
      if !ids.contains(id) { ids.append(id) }
      copy.vaultKeyIDs = ids
      changed.append(profile.id)
      return copy
    }
    return (next, changed)
  }

  /// 去掉所有主机对保险库密钥 `id` 的引用；列表变空时存成 nil（继承）。
  public static func removingReferences(to id: UUID, in hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    hosts.map { profile in
      guard let ids = profile.vaultKeyIDs, ids.contains(id) else { return profile }
      var copy = profile
      let remaining = ids.filter { $0 != id }
      copy.vaultKeyIDs = remaining.isEmpty ? nil : remaining
      return copy
    }
  }

  /// 引用了保险库密钥 `id` 的主机 ID（含默认项，只看主机自己写的列表，不算继承）。
  public static func hostsUsing(_ id: UUID, in hosts: [SSHHostProfile]) -> [UUID] {
    hosts.filter { $0.vaultKeyIDs?.contains(id) == true }.map(\.id)
  }

  /// 一台主机 `identityFiles` 里指向目标路径的下标。
  private static func matchingIndices(
    in profile: SSHHostProfile,
    target: String,
    defaults: SSHHostProfile,
    homeDirectory: String,
    localUser: String,
    canonicalize: (String) -> String
  ) -> Set<Int> {
    let user = [profile.user, defaults.user].first { !$0.isEmpty } ?? localUser
    var indices: Set<Int> = []
    for (index, template) in profile.identityFiles.enumerated() {
      if profile.isDefaults && (template.contains("%h") || template.contains("%r")) { continue }
      let expanded = SSHHostResolver.expandIdentity(
        template, host: profile.host, user: user, homeDirectory: homeDirectory)
      if canonicalize(expanded) == target { indices.insert(index) }
    }
    return indices
  }
}
