import AppKit
import AsterCore
import Foundation

// 保险库动作之「删除原私钥文件」：核对钥匙串副本、核对磁盘上的文件仍是同一把密钥、确认后删除；
// 以及生产环境的文件面板、文件读取与确认框。
//
// 删除不可撤销，所以只删 `~/.ssh` 下、且当场核对过指纹的文件：导入后原路径可能被换成别的密钥
// 或指向别处的软链，单看钥匙串副本会误删用户仍在用的另一把私钥。

extension SSHVaultKeyActions {
  // MARK: - 删除原私钥文件

  /// 删除原私钥文件。先回读钥匙串并核对指纹，再核对磁盘上的文件仍是这把密钥，列出仍引用它的主机与
  /// `~/.ssh/config`，用户在原生确认框里同意后再核对一次文件才删除；直接删除，不进废纸篓
  /// （废纸篓里的明文私钥等于没删）。
  func deleteOriginal(_ id: UUID) async -> Bool {
    guard let key = existingKey(id) else { return false }
    let path: String
    do {
      guard let importedFrom = key.importedFrom else { throw SSHVaultKeyActionError.notImported }
      guard dependencies.fileManager.fileExists(atPath: importedFrom) else {
        throw SSHVaultKeyActionError.originalMissing
      }
      path = importedFrom
    } catch {
      toast(Self.describe(error), true)
      return false
    }
    return await exclusive {
      do {
        try await verifyKeychainCopy(of: key)
        _ = try await verifyOriginalFile(of: key, at: path)
        let prompt = SSHVaultDeleteOriginalPrompt(
          path: SSHVaultMigration.canonicalPath(path),
          hostNames: migratableHosts(for: key, in: hosts.hosts).compactMap {
            hosts.host($0).map { $0.isDefaults ? L("默认") : $0.name }
          },
          sshConfigAliases: await sshConfigAliases(referencing: path))
        guard await dependencies.confirmDeleteOriginal(prompt, window()) else { return false }
        // 确认框可能开了很久：删除前再核对一次，缩小「核对后被替换」的窗口。核对之后到删除之间
        // 没有挂起点，删的正是刚核对过的解析路径。
        let resolved = try await verifyOriginalFile(of: key, at: path)
        try removeOriginal(at: path, resolved: resolved)
        onChange()
        toast(L("已删除原私钥文件"), false)
        return true
      } catch {
        toast(L("没有删除原私钥文件：\(Self.describe(error))"), true)
        return false
      }
    }
  }

  /// 回读钥匙串里的私钥并重新计算指纹，确认删除原文件后私钥仍然可用。
  private func verifyKeychainCopy(of key: SSHVaultKey) async throws {
    guard let tool = dependencies.tool() else { throw SSHVaultKeyActionError.runtimeMissing }
    let credentials = directory.credentials
    let id = key.id
    let stored = try await Task.detached { try credentials.vaultPrivateKey(id: id) }.value
    guard let stored else { throw SSHVaultKeyActionError.verificationFailed }
    let material = try await tool.inspect(privateKey: stored, passphrase: nil, comment: nil)
    guard material.fingerprint == key.fingerprint else { throw SSHVaultKeyActionError.verificationFailed }
  }

  /// 核对磁盘上的原文件（解析软链后）仍是这把密钥，返回解析后的路径。
  ///
  /// 解析后的路径必须在 `~/.ssh` 下。未加密时用 `keys inspect` 重算指纹；加密时不问 passphrase，
  /// 改用旁边 `.pub` 文件的指纹（先看解析后路径旁的，再看原路径旁的），私钥文件本身仍须存在。
  private func verifyOriginalFile(of key: SSHVaultKey, at path: String) async throws -> String {
    let resolved = SSHVaultMigration.canonicalPath(path)
    guard Self.isInsideSSHDirectory(resolved, homeDirectory: dependencies.homeDirectory) else {
      throw SSHVaultKeyActionError.originalOutsideSSHDirectory
    }
    guard dependencies.fileManager.fileExists(atPath: resolved) else {
      throw SSHVaultKeyActionError.originalMissing
    }
    guard let tool = dependencies.tool() else { throw SSHVaultKeyActionError.runtimeMissing }
    let read = dependencies.readKeyFile
    let text = try await Task.detached { try read(URL(fileURLWithPath: resolved)) }.value
    do {
      let material = try await tool.inspect(privateKey: text, passphrase: nil, comment: nil)
      guard material.fingerprint == key.fingerprint else { throw SSHVaultKeyActionError.originalChanged }
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
        throw SSHVaultKeyActionError.originalUnverifiable
      }
    } catch SSHVaultKeyToolError.invalid, SSHVaultKeyToolError.unsupported {
      throw SSHVaultKeyActionError.originalChanged
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

  // MARK: - 生产实现

  /// 打开文件面板选私钥：从 `~/.ssh` 开始，显示隐藏文件。
  static func chooseKeyFile(_ window: NSWindow?) async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message = L("选择要导入保险库的私钥文件")
    panel.prompt = L("导入")
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
    let response: NSApplication.ModalResponse
    if let window {
      response = await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      }
    } else {
      response = panel.runModal()
    }
    return response == .OK ? panel.url : nil
  }

  /// 读取私钥文件；超过上限或不是 UTF-8 文本按无效处理。
  nonisolated static func readKeyFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumKeyFileBytes + 1) ?? Data()
    guard data.count <= maximumKeyFileBytes, let text = String(data: data, encoding: .utf8) else {
      throw SSHVaultKeyActionError.invalidKeyFile
    }
    return text
  }

  /// 删除原文件前的原生确认框，写清所有后果。
  static func confirmDeleteOriginal(_ prompt: SSHVaultDeleteOriginalPrompt, window: NSWindow?) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = L("删除原私钥文件？")
    var lines = [
      prompt.path,
      L("私钥已安全存进钥匙串并核对过指纹。文件会被直接删除，不进废纸篓；同名 .pub 公钥文件保留。"),
      L("删除后，OpenSSH 回退引擎、手动输入的 ssh 命令和其它工具都无法再使用这把密钥；备份里可能仍有副本。"),
    ]
    if !prompt.hostNames.isEmpty {
      lines.append(L("这些主机的私钥文件仍指向它：\(prompt.hostNames.joined(separator: "、"))"))
    }
    switch prompt.sshConfigAliases {
    case .some(let aliases) where !aliases.isEmpty:
      lines.append(L("~/.ssh/config 中这些 Host 的 IdentityFile 指向它：\(aliases.joined(separator: "、"))"))
    case .none:
      lines.append(L("没能读取 ~/.ssh/config，无法确认其中是否还引用这个文件。"))
    default:
      break
    }
    alert.informativeText = lines.joined(separator: "\n\n")
    alert.addButton(withTitle: L("删除文件"))
    alert.addButton(withTitle: L("取消"))
    alert.buttons.first?.hasDestructiveAction = true
    if let window {
      return await withCheckedContinuation { continuation in
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
      }
    }
    return alert.runModal() == .alertFirstButtonReturn
  }
}
