import AppKit
import AsterCore
import Foundation

// 「密钥」子页的「删除原私钥文件」：核对钥匙串副本、核对磁盘上的文件仍是同一把密钥、确认后删除。
//
// 删除不可撤销，所以只删 `~/.ssh` 下、且当场核对过指纹的文件：导入后原路径可能被换成别的密钥
// 或指向别处的软链，单看钥匙串副本会误删用户仍在用的另一把私钥。

extension SettingsSSHKeysBridge {
  // MARK: - 删除原私钥文件

  /// 删除原私钥文件。先回读钥匙串并核对指纹，再核对磁盘上的文件仍是这把密钥，列出仍引用它的主机与
  /// `~/.ssh/config`，用户在原生确认框里同意后再核对一次文件才删除；直接删除，不进废纸篓
  /// （废纸篓里的明文私钥等于没删）。
  func deleteOriginal(_ payload: [String: Any], complete: @escaping (Bool) -> Void) {
    let key: SSHVaultKey
    do {
      key = try vaultKey(payload)
      guard let path = key.importedFrom else { throw SettingsSSHKeysError.notImported }
      guard dependencies.fileManager.fileExists(atPath: path) else {
        throw SettingsSSHKeysError.originalMissing
      }
    } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    runExclusive(complete: complete) { [weak self] in
      guard let self, let path = key.importedFrom else { return false }
      do {
        try await self.verifyKeychainCopy(of: key)
        _ = try await self.verifyOriginalFile(of: key, at: path)
        let prompt = SSHVaultDeleteOriginalPrompt(
          path: SSHVaultMigration.canonicalPath(path),
          hostNames: self.migratableHosts(for: key, in: self.hosts.hosts).compactMap {
            self.hosts.host($0).map { $0.isDefaults ? L("默认") : $0.name }
          },
          sshConfigAliases: await self.sshConfigAliases(referencing: path))
        guard await self.dependencies.confirmDeleteOriginal(prompt, self.window()) else { return false }
        // 确认框可能开了很久：删除前再核对一次，缩小「核对后被替换」的窗口。核对之后到删除之间
        // 没有挂起点，删的正是刚核对过的解析路径。
        let resolved = try await self.verifyOriginalFile(of: key, at: path)
        try self.removeOriginal(at: path, resolved: resolved)
        self.pushSnapshot()
        self.toast(L("已删除原私钥文件"), false)
        return true
      } catch {
        self.toast(L("没有删除原私钥文件：\(Self.describe(error))"), true)
        return false
      }
    }
  }

  /// 回读钥匙串里的私钥并重新计算指纹，确认删除原文件后私钥仍然可用。
  private func verifyKeychainCopy(of key: SSHVaultKey) async throws {
    guard let tool = dependencies.tool() else { throw SettingsSSHKeysError.runtimeMissing }
    let credentials = directory.credentials
    let id = key.id
    let stored = try await Task.detached { try credentials.vaultPrivateKey(id: id) }.value
    guard let stored else { throw SettingsSSHKeysError.verificationFailed }
    let material = try await tool.inspect(privateKey: stored, passphrase: nil, comment: nil)
    guard material.fingerprint == key.fingerprint else { throw SettingsSSHKeysError.verificationFailed }
  }

  /// 核对磁盘上的原文件（解析软链后）仍是这把密钥，返回解析后的路径。
  ///
  /// 解析后的路径必须在 `~/.ssh` 下。未加密时用 `keys inspect` 重算指纹；加密时不问 passphrase，
  /// 改用旁边 `.pub` 文件的指纹（先看解析后路径旁的，再看原路径旁的），私钥文件本身仍须存在。
  private func verifyOriginalFile(of key: SSHVaultKey, at path: String) async throws -> String {
    let resolved = SSHVaultMigration.canonicalPath(path)
    guard Self.isInsideSSHDirectory(resolved, homeDirectory: dependencies.homeDirectory) else {
      throw SettingsSSHKeysError.originalOutsideSSHDirectory
    }
    guard dependencies.fileManager.fileExists(atPath: resolved) else {
      throw SettingsSSHKeysError.originalMissing
    }
    guard let tool = dependencies.tool() else { throw SettingsSSHKeysError.runtimeMissing }
    let read = dependencies.readKeyFile
    let text = try await Task.detached { try read(URL(fileURLWithPath: resolved)) }.value
    do {
      let material = try await tool.inspect(privateKey: text, passphrase: nil, comment: nil)
      guard material.fingerprint == key.fingerprint else { throw SettingsSSHKeysError.originalChanged }
    } catch SSHVaultKeyToolError.encrypted {
      let candidates = [resolved, URL(fileURLWithPath: path).standardizedFileURL.path]
        .reduce(into: [String]()) { list, base in
          if !list.contains(base + ".pub") { list.append(base + ".pub") }
        }
        .filter { dependencies.fileManager.fileExists(atPath: $0) }
      let fingerprints = try await Task.detached {
        try candidates.map {
          SSHPublicKeyFingerprint.sha256(publicKeyFile: try read(URL(fileURLWithPath: $0)))
        }
      }.value
      guard fingerprints.contains(key.fingerprint) else {
        throw SettingsSSHKeysError.originalUnverifiable
      }
    } catch SSHVaultKeyToolError.invalid, SSHVaultKeyToolError.unsupported {
      throw SettingsSSHKeysError.originalChanged
    }
    return resolved
  }

  /// 已解析软链的路径是否在 `~/.ssh` 目录里（`~/.ssh` 本身也先解析软链）。
  nonisolated static func isInsideSSHDirectory(_ resolved: String, homeDirectory: String) -> Bool {
    let directory = SSHVaultMigration.canonicalPath(
      URL(fileURLWithPath: homeDirectory).appendingPathComponent(".ssh").path)
    return resolved.hasPrefix(directory + "/")
  }

  /// `~/.ssh/config` 里 IdentityFile 指向该文件的 Host 别名；读取失败返回 nil。
  private func sshConfigAliases(referencing path: String) async -> [String]? {
    let listing: SSHConfigListing
    do { listing = try await dependencies.configListing() } catch { return nil }
    let target = SSHVaultMigration.canonicalPath(path)
    let home = dependencies.homeDirectory
    return listing.hosts.filter { entry in
      entry.identityFiles.contains { template in
        let expanded = SSHHostResolver.expandIdentity(
          template, host: entry.hostName ?? entry.alias, user: entry.user ?? dependencies.localUser,
          homeDirectory: home)
        return SSHVaultMigration.canonicalPath(expanded) == target
      }
    }.map(\.alias)
  }

  /// 删除已核对的原文件 `resolved`。原路径是软链时再删掉留下的悬空链接。
  private func removeOriginal(at path: String, resolved: String) throws {
    let fileManager = dependencies.fileManager
    try fileManager.removeItem(atPath: resolved)
    if resolved != URL(fileURLWithPath: path).standardizedFileURL.path,
      (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    {
      try fileManager.removeItem(atPath: path)
    }
  }
}
