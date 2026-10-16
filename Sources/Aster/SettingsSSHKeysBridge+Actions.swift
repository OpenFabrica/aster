import AppKit
import AsterCore
import Foundation

// 「密钥」子页的动作：导入、生成、改名、复制公钥、删除、迁移主机引用；删除原私钥文件在
// SettingsSSHKeysBridge+Original.swift。
// 每个动作都以 `complete(succeeded)` 结束，SettingsViewController 据此给网页发回执。

/// 密钥动作失败的原因。文案直接给用户看。
enum SettingsSSHKeysError: Error, Equatable {
  case invalidPayload
  case unknownKey
  case invalidLabel
  case invalidKeyFile
  case runtimeMissing
  case notImported
  case originalMissing
  case verificationFailed
  case originalChanged
  case originalUnverifiable
  case originalOutsideSSHDirectory

  var message: String {
    switch self {
    case .invalidPayload: L("密钥参数无效")
    case .unknownKey: L("密钥不存在，可能已被删除")
    case .invalidLabel: L("名称不能为空，不能超过 64 字节，也不能包含换行")
    case .invalidKeyFile: L("文件过大或不是文本私钥")
    case .runtimeMissing: L("找不到 aster-ssh，请重新构建 Aster.app")
    case .notImported: L("这把密钥不是从文件导入的")
    case .originalMissing: L("原私钥文件已不存在")
    case .verificationFailed: L("钥匙串里的私钥与记录的指纹不一致，已取消删除原文件")
    case .originalChanged: L("原私钥文件已被改动，与保险库里的密钥不是同一把，已取消删除")
    case .originalUnverifiable: L("原私钥文件已加密，且旁边没有能对上指纹的 .pub 文件，无法确认是同一把密钥，已取消删除")
    case .originalOutsideSSHDirectory: L("原私钥文件不在 ~/.ssh 目录下，Aster 不会删除它，请手动删除")
    }
  }
}

extension SettingsSSHKeysBridge {
  // MARK: - 导入

  /// 导入私钥文件：原生选择与读取，`aster-ssh keys inspect` 解析；加密时最多问三次 passphrase。
  /// 指纹已在保险库里时复用已有条目，不重复写钥匙串。
  func importKey(complete: @escaping (Bool) -> Void) {
    runExclusive(complete: complete) { [weak self] in
      guard let self else { return false }
      guard let url = await self.dependencies.chooseKeyFile(self.window()) else { return false }
      do {
        guard let tool = self.dependencies.tool() else { throw SettingsSSHKeysError.runtimeMissing }
        let read = self.dependencies.readKeyFile
        let text = try await Task.detached { try read(url) }.value
        guard let material = try await self.inspect(text, keyFile: url.path, tool: tool) else {
          return false
        }
        if let existing = self.directory.key(fingerprint: material.fingerprint) {
          self.toast(L("这把密钥已在保险库中：“\(existing.label)”"), false)
          return true
        }
        let key = SSHVaultKey(
          label: Self.defaultLabel(for: url, comment: material.comment),
          algorithm: material.algorithm, fingerprint: material.fingerprint,
          publicKey: material.publicKey, comment: material.comment, origin: .imported,
          importedFrom: url.standardizedFileURL.path)
        try await self.directory.add(key, privateKey: material.privateKey)
        self.pushSnapshot()
        self.toast(L("已导入“\(key.label)”"), false)
        return true
      } catch {
        self.toast(L("无法导入私钥：\(Self.describe(error))"), true)
        return false
      }
    }
  }

  /// 解析私钥；加密时询问 passphrase。用户取消返回 nil。
  private func inspect(
    _ text: String, keyFile: String, tool: any SSHVaultKeyTooling
  ) async throws -> SSHVaultKeyMaterial? {
    do {
      return try await tool.inspect(privateKey: text, passphrase: nil, comment: nil)
    } catch SSHVaultKeyToolError.encrypted {
      var isRetry = false
      for _ in 0..<Self.maximumPassphraseAttempts {
        guard let passphrase = await dependencies.promptPassphrase(keyFile, isRetry) else {
          return nil
        }
        do {
          return try await tool.inspect(privateKey: text, passphrase: passphrase, comment: nil)
        } catch SSHVaultKeyToolError.wrongPassphrase {
          isRetry = true
        }
      }
      throw SSHVaultKeyToolError.wrongPassphrase
    }
  }

  /// 导入密钥的默认名称：文件名；`id_*` 这类通用名后面补上注释，便于区分。
  static func defaultLabel(for url: URL, comment: String) -> String {
    let name = url.lastPathComponent
    let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = name.hasPrefix("id_") && !trimmed.isEmpty ? "\(name) (\(trimmed))" : name
    // 按字符截断到名称上限，不切断多字节字符；控制字符换成空格，保证能通过校验。
    var label = ""
    for character in candidate {
      let text = character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        ? " " : String(character)
      guard label.utf8.count + text.utf8.count <= SSHVaultKeyStore.maximumLabelBytes else { break }
      label += text
    }
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    return trimmedLabel.isEmpty ? L("导入的密钥") : trimmedLabel
  }

  // MARK: - 生成、改名、复制

  /// 生成一把 ed25519 密钥并存进保险库。
  func generate(_ payload: [String: Any], complete: @escaping (Bool) -> Void) {
    let label: String
    let comment: String
    do {
      label = try Self.validatedLabel(payload["label"])
      let rawComment = (payload["comment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard rawComment.utf8.count <= 256,
        !rawComment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { throw SettingsSSHKeysError.invalidPayload }
      comment = rawComment
    } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    runExclusive(complete: complete) { [weak self] in
      guard let self else { return false }
      do {
        guard let tool = self.dependencies.tool() else { throw SettingsSSHKeysError.runtimeMissing }
        let material = try await tool.generate(comment: comment)
        let key = SSHVaultKey(
          label: label, algorithm: material.algorithm, fingerprint: material.fingerprint,
          publicKey: material.publicKey, comment: material.comment, origin: .generated)
        try await self.directory.add(key, privateKey: material.privateKey)
        self.pushSnapshot()
        self.toast(L("已生成“\(label)”，可以复制公钥添加到服务器"), false)
        return true
      } catch {
        self.toast(L("无法生成密钥：\(Self.describe(error))"), true)
        return false
      }
    }
  }

  /// 改名。
  func rename(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let key = try vaultKey(payload)
      try directory.rename(key.id, label: try Self.validatedLabel(payload["label"]))
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  /// 把公钥复制到剪贴板（原生写入，网页不经手）。
  func copyPublicKey(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let key = try vaultKey(payload)
      dependencies.copyToPasteboard(key.publicKey)
      toast(L("已复制“\(key.label)”的公钥"), false)
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  // MARK: - 删除与迁移

  /// 删除保险库密钥：目录、钥匙串与主机引用一起清理。网页已列出引用它的主机让用户确认。
  /// 钥匙串删除在后台进行，期间用 `runExclusive` 挡住其它密钥动作。
  func delete(_ payload: [String: Any], complete: @escaping (Bool) -> Void) {
    let key: SSHVaultKey
    do {
      key = try vaultKey(payload)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    runExclusive(complete: complete) { [weak self] in
      guard let self else { return false }
      do {
        do {
          try await self.directory.remove(key.id)
        } catch SSHVaultKeyDirectoryError.keychainCleanupFailed {
          self.toast(L("密钥已从列表删除，但没能从钥匙串删除私钥"), true)
        }
        self.pushSnapshot()
        return true
      } catch {
        self.toast(Self.describe(error), true)
        return false
      }
    }
  }

  /// 把 `identityFiles` 里指向原文件的主机改为使用这把保险库密钥。
  func migrateReferences(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let key = try vaultKey(payload)
      guard let path = key.importedFrom else { throw SettingsSSHKeysError.notImported }
      let current = hosts.hosts
      let result = SSHVaultMigration.migratingReferences(
        path: path, to: key.id, in: current, homeDirectory: dependencies.homeDirectory,
        localUser: dependencies.localUser)
      if !result.changed.isEmpty {
        try hosts.store.save(result.hosts)
        hosts.reload()
      }
      pushSnapshot()
      toast(L("已把 \(result.changed.count) 台主机改为使用“\(key.label)”"), false)
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  // MARK: - 错误文案

  /// 把各类错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SettingsSSHKeysError: return error.message
    case SSHVaultKeyToolError.encrypted: return L("私钥已加密，需要 passphrase")
    case SSHVaultKeyToolError.wrongPassphrase: return L("passphrase 不正确")
    case SSHVaultKeyToolError.invalid: return L("不是可识别的私钥文件")
    case SSHVaultKeyToolError.unsupported: return L("不支持这种私钥格式或算法（支持 Ed25519、RSA、ECDSA）")
    case SSHVaultKeyToolError.runtime, SSHVaultKeyToolError.malformedOutput:
      return L("aster-ssh 运行失败")
    case SSHVaultKeyDirectoryError.unknownKey: return SettingsSSHKeysError.unknownKey.message
    case SSHVaultKeyDirectoryError.keychain(.keychain(let status)),
      SSHVaultKeyDirectoryError.keychainCleanupFailed(.keychain(let status)):
      return L("钥匙串操作失败（\(String(status))）")
    case SSHVaultKeyDirectoryError.store(.invalidKeys(let reasons)):
      if reasons.contains(where: { $0.hasSuffix("duplicate fingerprint") }) {
        return L("这把密钥已在保险库中")
      }
      return L("密钥信息无效：\(reasons.joined(separator: "；"))")
    case SSHVaultKeyDirectoryError.store(let error): return L("读写 ssh-keys.json 失败：\(String(describing: error))")
    case SSHCredentialStoreError.keychain(let status): return L("钥匙串操作失败（\(String(status))）")
    default: return SettingsHostsBridge.describe(error)
    }
  }
}
