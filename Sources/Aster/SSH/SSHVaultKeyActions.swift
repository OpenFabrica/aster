import AppKit
import AsterCore
import Foundation

// 私钥保险库的用户动作：导入、生成、改名、复制公钥、删除、迁移主机引用；删除原私钥文件在
// SSHVaultKeyActions+Original.swift。与具体界面无关：「主机 → 密钥」原生页与设置页的网页桥接
// 都调用这里，校验、错误文案与安全规则只有一份。
//
// 私钥只在原生侧流转：文件由 NSOpenPanel 选择后原生读取，passphrase 用原生表单询问，
// 私钥与 passphrase 不交给任何界面层，也不提供导出。保险库真值只在 `SSHVaultKeyDirectory`。

/// 删除原私钥文件前给用户看的内容。
struct SSHVaultDeleteOriginalPrompt: Equatable {
  /// 要删除的文件（已解析软链）。
  var path: String
  /// 仍在 `identityFiles` 里引用这个文件的主机名。
  var hostNames: [String]
  /// `~/.ssh/config` 里 IdentityFile 指向它的 Host 别名；nil 表示没能读取配置。
  var sshConfigAliases: [String]?
}

/// 保险库密钥动作服务。每个动作返回是否成功；失败原因、成功提示都经 `toast` 告诉用户。
@MainActor
final class SSHVaultKeyActions: ObservableObject {
  /// 外部依赖。生产用 `.live()`；测试注入临时目录、假钥匙串、假 `aster-ssh keys` 与假弹窗。
  struct Dependencies {
    var directory: SSHVaultKeyDirectory
    /// `aster-ssh keys` 调用；nil 表示找不到 aster-ssh。
    var tool: @MainActor () -> (any SSHVaultKeyTooling)?
    /// 选择要导入的私钥文件；取消返回 nil。
    var chooseKeyFile: @MainActor (NSWindow?) async -> URL?
    /// 读取私钥文件（有大小上限）。
    var readKeyFile: @Sendable (URL) throws -> String
    /// 询问加密私钥的 passphrase；取消返回 nil。
    var promptPassphrase: @MainActor (_ keyFile: String, _ isRetry: Bool) async -> String?
    /// 把公钥写进剪贴板。
    var copyToPasteboard: @MainActor (String) -> Void
    /// 删除原私钥文件前确认；true 表示删除。
    var confirmDeleteOriginal: @MainActor (SSHVaultDeleteOriginalPrompt, NSWindow?) async -> Bool
    /// 读取 `~/.ssh/config` 的解析结果。
    var configListing: @MainActor () async throws -> SSHConfigListing
    /// 当前 SSH 引擎；openssh 时保险库密钥不生效，界面显示提示。
    var engine: @MainActor () -> SSHEngine
    var fileManager: FileManager = .default
    var homeDirectory: String = NSHomeDirectory()
    var localUser: String = NSUserName()

    /// 生产依赖：共享保险库目录、aster-ssh、NSOpenPanel 与原生表单。
    @MainActor static func live() -> Dependencies {
      Dependencies(
        directory: .shared,
        tool: { SSHRuntimeTool.located().map { SSHVaultKeyTool(runtime: $0) } },
        chooseKeyFile: SSHVaultKeyActions.chooseKeyFile,
        readKeyFile: SSHVaultKeyActions.readKeyFile,
        promptPassphrase: { keyFile, isRetry in
          await SSHAuthSheet.promptSecret(
            SSHSecretPrompt(subject: .passphrase(keyFile: keyFile), isRetry: isRetry, canRemember: false)
          )?.secret
        },
        copyToPasteboard: { text in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        },
        confirmDeleteOriginal: SSHVaultKeyActions.confirmDeleteOriginal,
        configListing: { try await SSHBrokerSupervisor.shared.configListing() },
        engine: { SSHBrokerSupervisor.shared.engine })
    }
  }

  /// 私钥文件读取上限，与 `aster-ssh keys` 的 stdin 上限一致。
  nonisolated static let maximumKeyFileBytes = 64 * 1024
  /// 加密私钥最多询问几次 passphrase。
  static let maximumPassphraseAttempts = 3
  /// 注释上限（字节），与公钥行一起写进 authorized_keys。
  static let maximumCommentBytes = 256

  let dependencies: Dependencies
  /// 删除密钥、迁移引用时改写的主机目录。
  let hosts: SSHHostDirectory
  var directory: SSHVaultKeyDirectory { dependencies.directory }

  /// 动作改动了目录或主机之后调用（网页桥接据此立即推快照；原生页直接观察目录，可以不设）。
  var onChange: () -> Void = {}
  /// 显示一条提示；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }
  /// 打开面板与确认框的宿主窗口。
  var window: () -> NSWindow? = { nil }
  /// 有一个需要等待用户或子进程的动作在进行。同一时刻只跑一个，避免两次导入或删除交叠；
  /// 界面据此禁用按钮。
  @Published private(set) var isBusy = false

  init(dependencies: Dependencies, hosts: SSHHostDirectory) {
    self.dependencies = dependencies
    self.hosts = hosts
  }

  // MARK: - 展示数据

  /// 按名称排序的展示行。主机名、迁移候选与钥匙串缺失标记都在这里统一计算。
  func rows(hosts: [SSHHostProfile]) -> [SSHVaultKeyRow] {
    let names = Dictionary(
      hosts.map { ($0.id, $0.isDefaults ? L("默认") : $0.name) }, uniquingKeysWith: { first, _ in first })
    return directory.keys
      .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
      .map { key in
        SSHVaultKeyRow(
          key: key,
          usedBy: SSHVaultMigration.hostsUsing(key.id, in: hosts).compactMap { names[$0] },
          migratableHosts: migratableHosts(for: key, in: hosts).compactMap { names[$0] },
          originalExists: key.importedFrom.map { dependencies.fileManager.fileExists(atPath: $0) } ?? false,
          // 读缓存而不是当场查钥匙串：每次刷新列表都会走到这里，逐把查会卡住主线程。
          keychainMissing: directory.keychainMissing.contains(key.id))
      }
  }

  /// `identityFiles` 仍指向这把密钥原文件的主机 ID；生成的密钥没有原文件。
  func migratableHosts(for key: SSHVaultKey, in hosts: [SSHHostProfile]) -> [UUID] {
    guard let path = key.importedFrom else { return [] }
    return SSHVaultMigration.hostsReferencing(
      path: path, in: hosts, homeDirectory: dependencies.homeDirectory,
      localUser: dependencies.localUser)
  }

  // MARK: - 互斥与校验

  /// 在 `isBusy` 保护下运行一个异步动作；已有动作在进行时直接返回失败。
  func exclusive(_ work: () async -> Bool) async -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    defer { isBusy = false }
    return await work()
  }

  /// 找一把保险库密钥；不存在时提示并返回 nil。
  func existingKey(_ id: UUID) -> SSHVaultKey? {
    guard let key = directory.key(id) else {
      toast(SSHVaultKeyActionError.unknownKey.message, true)
      return nil
    }
    return key
  }

  /// 校验并规范化名称：去首尾空白，非空，不超过上限，不含控制字符。
  static func validatedLabel(_ text: String) throws -> String {
    let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label.utf8.count <= SSHVaultKeyStore.maximumLabelBytes,
      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SSHVaultKeyActionError.invalidLabel }
    return label
  }

  /// 校验并规范化注释：去首尾空白，可以为空，不超过上限，不含控制字符。
  static func validatedComment(_ text: String) throws -> String {
    let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard comment.utf8.count <= maximumCommentBytes,
      !comment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SSHVaultKeyActionError.invalidComment }
    return comment
  }

  // MARK: - 导入

  /// 导入私钥文件：原生选择与读取，`aster-ssh keys inspect` 解析；加密时最多问三次 passphrase。
  /// 指纹已在保险库里时复用已有条目，不重复写钥匙串。用户取消返回 false 且不提示。
  func importKey() async -> Bool {
    await exclusive {
      guard let url = await dependencies.chooseKeyFile(window()) else { return false }
      do {
        guard let tool = dependencies.tool() else { throw SSHVaultKeyActionError.runtimeMissing }
        let read = dependencies.readKeyFile
        let text = try await Task.detached { try read(url) }.value
        guard let material = try await inspect(text, keyFile: url.path, tool: tool) else { return false }
        if let existing = directory.key(fingerprint: material.fingerprint) {
          toast(L("这把密钥已在保险库中：“\(existing.label)”"), false)
          return true
        }
        let key = SSHVaultKey(
          label: Self.defaultLabel(for: url, comment: material.comment),
          algorithm: material.algorithm, fingerprint: material.fingerprint,
          publicKey: material.publicKey, comment: material.comment, origin: .imported,
          importedFrom: url.standardizedFileURL.path)
        try await directory.add(key, privateKey: material.privateKey)
        onChange()
        toast(L("已导入“\(key.label)”"), false)
        return true
      } catch {
        toast(L("无法导入私钥：\(Self.describe(error))"), true)
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

  /// 生成一把 ed25519 密钥并存进保险库。名称与注释先校验，校验失败不占用 `isBusy`。
  func generate(label rawLabel: String, comment rawComment: String) async -> Bool {
    let label: String
    let comment: String
    do {
      label = try Self.validatedLabel(rawLabel)
      comment = try Self.validatedComment(rawComment)
    } catch {
      toast(Self.describe(error), true)
      return false
    }
    return await exclusive {
      do {
        guard let tool = dependencies.tool() else { throw SSHVaultKeyActionError.runtimeMissing }
        let material = try await tool.generate(comment: comment)
        let key = SSHVaultKey(
          label: label, algorithm: material.algorithm, fingerprint: material.fingerprint,
          publicKey: material.publicKey, comment: material.comment, origin: .generated)
        try await directory.add(key, privateKey: material.privateKey)
        onChange()
        toast(L("已生成“\(label)”，可以复制公钥添加到服务器"), false)
        return true
      } catch {
        toast(L("无法生成密钥：\(Self.describe(error))"), true)
        return false
      }
    }
  }

  /// 改名。只改目录，钥匙串条目的显示名不跟着改（见 `SSHVaultKeyDirectory.rename`）。
  func rename(_ id: UUID, label: String) -> Bool {
    guard existingKey(id) != nil else { return false }
    do {
      try directory.rename(id, label: try Self.validatedLabel(label))
      onChange()
      return true
    } catch {
      toast(Self.describe(error), true)
      return false
    }
  }

  /// 把公钥复制到剪贴板（原生写入）。
  func copyPublicKey(_ id: UUID) -> Bool {
    guard let key = existingKey(id) else { return false }
    dependencies.copyToPasteboard(key.publicKey)
    toast(L("已复制“\(key.label)”的公钥"), false)
    return true
  }

  // MARK: - 删除与迁移

  /// 删除保险库密钥：目录、钥匙串与主机引用一起清理。调用方已列出引用它的主机让用户确认。
  /// 钥匙串删除在后台进行，期间用 `isBusy` 挡住其它密钥动作。
  func delete(_ id: UUID) async -> Bool {
    guard let key = existingKey(id) else { return false }
    return await exclusive {
      do {
        do {
          try await directory.remove(key.id)
        } catch SSHVaultKeyDirectoryError.keychainCleanupFailed {
          toast(L("密钥已从列表删除，但没能从钥匙串删除私钥"), true)
        }
        onChange()
        return true
      } catch {
        toast(Self.describe(error), true)
        return false
      }
    }
  }

  /// 把 `identityFiles` 里指向原文件的主机改为使用这把保险库密钥。
  func migrateReferences(_ id: UUID) -> Bool {
    guard let key = existingKey(id) else { return false }
    do {
      guard let path = key.importedFrom else { throw SSHVaultKeyActionError.notImported }
      let result = SSHVaultMigration.migratingReferences(
        path: path, to: key.id, in: hosts.hosts, homeDirectory: dependencies.homeDirectory,
        localUser: dependencies.localUser)
      if !result.changed.isEmpty {
        try hosts.store.save(result.hosts)
        hosts.reload()
      }
      onChange()
      // 插值必须是 String，Int 会生成 `%lld` key 而查不到翻译。
      toast(L("已把 \(String(result.changed.count)) 台主机改为使用“\(key.label)”"), false)
      return true
    } catch {
      toast(Self.describe(error), true)
      return false
    }
  }
}
