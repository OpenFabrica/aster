import AppKit
import AsterCore
import Foundation

// 设置页「主机 › 密钥」子页的桥接协作者：为网页生成保险库快照，并执行 `hosts.keys.` 前缀的动作。
//
// 由 `SettingsHostsBridge` 持有并转发动作；推送快照、toast、取窗口沿用它注入的闭包。
// 私钥只在原生侧流转：文件由 NSOpenPanel 选择后原生读取，passphrase 用原生表单询问，
// 私钥与 passphrase 从不经过 WKWebView。保险库真值只在 `SSHVaultKeyDirectory`。

/// 删除原私钥文件前给用户看的内容。
struct SSHVaultDeleteOriginalPrompt: Equatable {
  /// 要删除的文件（已解析软链）。
  var path: String
  /// 仍在 `identityFiles` 里引用这个文件的主机名。
  var hostNames: [String]
  /// `~/.ssh/config` 里 IdentityFile 指向它的 Host 别名；nil 表示没能读取配置。
  var sshConfigAliases: [String]?
}

/// 「密钥」子页的快照与动作处理。
@MainActor
final class SettingsSSHKeysBridge {
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
    /// 当前 SSH 引擎；openssh 时保险库密钥不生效，网页显示提示。
    var engine: @MainActor () -> SSHEngine
    var fileManager: FileManager = .default
    var homeDirectory: String = NSHomeDirectory()
    var localUser: String = NSUserName()

    /// 生产依赖：共享保险库目录、aster-ssh、NSOpenPanel 与原生表单。
    @MainActor static func live() -> Dependencies {
      Dependencies(
        directory: .shared,
        tool: { SSHRuntimeTool.located().map { SSHVaultKeyTool(runtime: $0) } },
        chooseKeyFile: SettingsSSHKeysBridge.chooseKeyFile,
        readKeyFile: SettingsSSHKeysBridge.readKeyFile,
        promptPassphrase: { keyFile, isRetry in
          await SSHAuthSheet.promptSecret(
            SSHSecretPrompt(subject: .passphrase(keyFile: keyFile), isRetry: isRetry, canRemember: false)
          )?.secret
        },
        copyToPasteboard: { text in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        },
        confirmDeleteOriginal: SettingsSSHKeysBridge.confirmDeleteOriginal,
        configListing: { try await SSHBrokerSupervisor.shared.configListing() },
        engine: { SSHBrokerSupervisor.shared.engine })
    }
  }

  /// 私钥文件读取上限，与 `aster-ssh keys` 的 stdin 上限一致。
  nonisolated static let maximumKeyFileBytes = 64 * 1024
  /// 加密私钥最多询问几次 passphrase。
  static let maximumPassphraseAttempts = 3

  let dependencies: Dependencies
  /// 删除密钥、迁移引用时改写的主机目录。
  let hosts: SSHHostDirectory
  var directory: SSHVaultKeyDirectory { dependencies.directory }

  /// 立即推送一份新快照。
  var pushSnapshot: () -> Void = {}
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }
  /// 设置窗口，用作打开面板与确认框的宿主。
  var window: () -> NSWindow? = { nil }
  /// 有一个需要等待用户或子进程的动作在进行。网页的回执 5 秒就超时，按钮会提前恢复，
  /// 连点时靠它只跑一次，避免两次导入或删除交叠。
  var isBusy = false

  init(dependencies: Dependencies, hosts: SSHHostDirectory) {
    self.dependencies = dependencies
    self.hosts = hosts
  }

  // MARK: - 快照

  /// 合并进主机快照的字段：`vaultKeys`、`vaultKeysError`、`sshEngine`。
  ///
  /// `vaultKeys` 每项：id、label、algorithm、fingerprint、publicKey、comment、createdAt（ISO 8601）、
  /// origin、importedFrom（缩写成 ~）、usedBy（引用它的主机名）、migratableHosts（`identityFiles`
  /// 仍指向原文件的主机名）、originalExists、keychainMissing。
  func snapshot(hosts: [SSHHostProfile]) -> [String: Any] {
    let names = Dictionary(
      hosts.map { ($0.id, $0.isDefaults ? L("默认") : $0.name) }, uniquingKeysWith: { first, _ in first })
    let formatter = ISO8601DateFormatter()
    let keys = directory.keys.sorted {
      $0.label.localizedStandardCompare($1.label) == .orderedAscending
    }
    let rows: [[String: Any]] = keys.map { key in
      var row: [String: Any] = [
        "id": key.id.uuidString,
        "label": key.label,
        "algorithm": key.algorithm,
        "fingerprint": key.fingerprint,
        "publicKey": key.publicKey,
        "comment": key.comment,
        "createdAt": formatter.string(from: key.createdAt),
        "origin": key.origin.rawValue,
        "usedBy": SSHVaultMigration.hostsUsing(key.id, in: hosts).compactMap { names[$0] },
        "migratableHosts": migratableHosts(for: key, in: hosts).compactMap { names[$0] },
        "originalExists": key.importedFrom.map { dependencies.fileManager.fileExists(atPath: $0) } ?? false,
        "keychainMissing": !directory.credentials.hasVaultPrivateKey(id: key.id),
      ]
      row["importedFrom"] = key.importedFrom.map { ($0 as NSString).abbreviatingWithTildeInPath }
      return row
    }
    return [
      "vaultKeys": rows,
      "vaultKeysError": directory.loadError ?? "",
      "sshEngine": dependencies.engine().rawValue,
    ]
  }

  /// `identityFiles` 仍指向这把密钥原文件的主机 ID；生成的密钥没有原文件。
  func migratableHosts(for key: SSHVaultKey, in hosts: [SSHHostProfile]) -> [UUID] {
    guard let path = key.importedFrom else { return [] }
    return SSHVaultMigration.hostsReferencing(
      path: path, in: hosts, homeDirectory: dependencies.homeDirectory,
      localUser: dependencies.localUser)
  }

  // MARK: - 动作分发

  /// 分发一个 `hosts.keys.` 前缀的动作。未知动作 toast 报错并回执失败。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    switch action {
    case "hosts.keys.import": importKey(complete: complete)
    case "hosts.keys.generate": generate(payload, complete: complete)
    case "hosts.keys.rename": rename(payload, complete: complete)
    case "hosts.keys.copyPublicKey": copyPublicKey(payload, complete: complete)
    case "hosts.keys.delete": delete(payload, complete: complete)
    case "hosts.keys.migrateReferences": migrateReferences(payload, complete: complete)
    case "hosts.keys.deleteOriginal": deleteOriginal(payload, complete: complete)
    default:
      toast(L("“\(action)”尚无可用的 macOS 操作"), true)
      complete(false)
    }
  }

  /// 在 `isBusy` 保护下运行一个异步动作；已有动作在进行时直接回执失败。
  func runExclusive(
    complete: @escaping (Bool) -> Void, _ work: @escaping @MainActor () async -> Bool
  ) {
    guard !isBusy else {
      complete(false)
      return
    }
    isBusy = true
    Task { @MainActor [weak self] in
      let succeeded = await work()
      self?.isBusy = false
      complete(succeeded)
    }
  }

  /// 按 payload 里的 `id` 找一把保险库密钥。
  func vaultKey(_ payload: [String: Any]) throws -> SSHVaultKey {
    guard let raw = payload["id"] as? String, let id = UUID(uuidString: raw) else {
      throw SettingsSSHKeysError.invalidPayload
    }
    guard let key = directory.key(id) else { throw SettingsSSHKeysError.unknownKey }
    return key
  }

  /// 校验并规范化名称：去首尾空白，非空，不超过上限，不含控制字符。
  static func validatedLabel(_ raw: Any?) throws -> String {
    guard let text = raw as? String else { throw SettingsSSHKeysError.invalidPayload }
    let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, label.utf8.count <= SSHVaultKeyStore.maximumLabelBytes,
      !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SettingsSSHKeysError.invalidLabel }
    return label
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
      throw SettingsSSHKeysError.invalidKeyFile
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
