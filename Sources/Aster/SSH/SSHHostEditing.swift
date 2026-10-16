import AppKit
import AsterCore
import Foundation

// 编辑已保存主机的共用规则：保存（清理 → 校验 → 落盘）、复制、忘记口令、删除影响与
// `~/.ssh/config` 文件操作。设置页网页桥与侧栏主机页的原生编辑面板都调用这里，
// 主机真值仍只在 `SSHHostDirectory`，合法性以 `SSHHostStore.validate` 与解析器为准。

/// 编辑主机失败的原因。文案直接给用户看。
enum SSHHostEditingError: Error, Equatable {
  case invalidPayload
  case unknownHost
  case invalidProfile([String])
  case noTextEditor

  var message: String {
    switch self {
    case .invalidPayload: L("主机参数无效")
    case .unknownHost: L("主机不存在，可能已被删除")
    case .invalidProfile(let reasons): L("主机配置无效：\(reasons.joined(separator: "；"))")
    case .noTextEditor: L("找不到可以打开纯文本文件的编辑器")
    }
  }
}

/// 主机口令的钥匙串能力：只判断与删除，读写口令本身由认证流程负责。
@MainActor
protocol SSHHostPasswordStore {
  /// 是否已为该 endpoint 保存口令。
  func hasPassword(for endpoint: String) -> Bool
  /// 删除该 endpoint 的口令；不存在不算错误。
  func deletePassword(for endpoint: String) throws
}

extension SSHCredentialStore: SSHHostPasswordStore {}

/// 删除一台主机前要告诉用户的影响。
struct SSHHostDeletionImpact: Equatable {
  /// 引用它的机器标签。
  var machines: [String]
  /// 用它作跳板的主机名称。
  var jumpDependents: [String]
  /// 与它共用同一口令 endpoint 的主机名称。
  var credentialSharedWith: [String]
}

/// 主机编辑规则。全部是无状态的静态函数，依赖都由参数传入，测试注入临时目录与假钥匙串。
@MainActor
enum SSHHostEditing {
  // MARK: - 保存

  /// 边界清理：空值归一、拒绝超量条目与控制字符，错误换成给用户看的形式。
  static func sanitize(_ profile: SSHHostProfile) throws -> SSHHostProfile {
    do {
      return try SSHHostEditRules.sanitized(profile)
    } catch .tooManyEntries {
      throw SSHHostEditingError.invalidPayload
    } catch .controlCharacters {
      throw SSHHostEditingError.invalidProfile([L("不能包含换行或控制字符")])
    }
  }

  /// 新增或更新一台主机（含默认项）：清理 → 整份校验 → 落盘，失败时不写文件。
  ///
  /// - Parameter requireExisting: 编辑已有主机时为 true；主机在编辑期间被删掉就报错，
  ///   不让保存把它悄悄加回来。
  /// - Returns: 实际写入的主机配置。
  @discardableResult
  static func save(
    _ profile: SSHHostProfile, in directory: SSHHostDirectory, requireExisting: Bool = false
  ) throws -> SSHHostProfile {
    let profile = try sanitize(profile)
    var candidate = directory.hosts
    if let index = candidate.firstIndex(where: { $0.id == profile.id }) {
      candidate[index] = profile
    } else {
      // 默认项总是存在（存储会补上），只有普通主机才可能在编辑期间被删。
      if requireExisting && !profile.isDefaults { throw SSHHostEditingError.unknownHost }
      candidate.append(profile)
    }
    try validate(profile, in: candidate)
    try directory.upsert(profile)
    return profile
  }

  /// 按存储规则校验候选列表，只报告与这台主机相关的原因；再确认跳板链可以解析。
  static func validate(_ profile: SSHHostProfile, in candidate: [SSHHostProfile]) throws {
    let normalized = SSHHostStore.normalized(candidate)
    let reasons = SSHHostStore.validate(normalized)
    if !reasons.isEmpty {
      let tag = normalized.firstIndex(where: { $0.id == profile.id }).map { "[\($0)]" }
      let own = reasons.filter { tag.map($0.hasPrefix) ?? true }
      throw SSHHostEditingError.invalidProfile((own.isEmpty ? reasons : own).map(friendlyReason))
    }
    guard !profile.isDefaults else { return }
    // validate 只挡「跳板是自己」；更长的环与过深的链要靠解析才能发现。
    do {
      _ = try SSHHostResolver.resolve(profile.id, in: normalized)
    } catch SSHHostResolutionError.jumpCycle {
      throw SSHHostEditingError.invalidProfile([L("跳板机形成了循环")])
    } catch SSHHostResolutionError.jumpTooDeep {
      throw SSHHostEditingError.invalidProfile(
        [L("跳板链超过 \(SSHHostResolver.maximumJumpDepth) 层")])
    } catch {
      throw SSHHostEditingError.invalidProfile([L("主机无法解析：\(String(describing: error))")])
    }
  }

  /// 把 `SSHHostStore.validate` 的英文原因换成给用户看的中文。
  static func friendlyReason(_ reason: String) -> String {
    switch SSHConfigImport.stripIndexTag(reason) {
    case "empty name": L("名称不能为空")
    case "empty host": L("主机不能为空")
    case "newline in host/user": L("主机和用户名不能换行")
    case "invalid group": L("分组名过长或包含换行")
    case "invalid tags": L("标签过长或包含逗号/换行")
    case "invalid port": L("端口必须在 1–65535 之间")
    case "invalid proxy": L("代理地址不能为空，端口必须在 1–65535 之间")
    case "invalid forward": L("端口转发的端口无效")
    case "invalid jumpHostID": L("跳板机无效：不能选自己，也不能选已删除的主机")
    case "negative timing": L("keepalive 与超时不能是负数")
    case "duplicate id": L("主机 ID 重复")
    case "invalid vaultKeyIDs": L("保险库密钥重复或超过 \(SSHHostStore.maximumVaultKeys) 把")
    case let other: other
    }
  }

  // MARK: - 复制、忘记口令、删除影响

  /// 复制一台已保存主机：新 ID、名称加「副本」，导入组的副本放到未分组。
  @discardableResult
  static func duplicate(_ id: UUID, in directory: SSHHostDirectory) throws -> SSHHostProfile {
    let source = try savedHost(id, in: directory)
    let copy = source.duplicated(name: L("\(source.name) 副本"))
    try directory.upsert(copy)
    return copy
  }

  /// 忘记这台主机 endpoint 的口令。共用 endpoint 的主机会一起失去口令，调用方负责事先提示。
  static func forgetPassword(
    _ id: UUID, in directory: SSHHostDirectory, passwords: any SSHHostPasswordStore
  ) throws {
    _ = try savedHost(id, in: directory)
    guard let endpoint = credentialEndpoints(directory.hosts)[id] else {
      throw SSHHostEditingError.invalidProfile([L("主机无法解析，找不到对应的口令")])
    }
    try passwords.deletePassword(for: endpoint)
  }

  /// 删除前的影响统计：引用它的机器、用它作跳板的主机、共用口令的主机。
  static func deletionImpact(
    of id: UUID, hosts: [SSHHostProfile], machines: [MachineProfile]
  ) -> SSHHostDeletionImpact {
    SSHHostDeletionImpact(
      machines: machines.filter { $0.hostID == id }.map(\.label),
      jumpDependents: SSHHostStore.hostsUsingJump(id, in: hosts).map(\.name),
      credentialSharedWith: SSHHostStore.hostsSharingCredential(with: id, in: hosts).map(\.name))
  }

  /// 按 ID 找一台已保存主机（不含默认项）。
  static func savedHost(_ id: UUID, in directory: SSHHostDirectory) throws -> SSHHostProfile {
    guard let profile = directory.host(id), !profile.isDefaults else {
      throw SSHHostEditingError.unknownHost
    }
    return profile
  }

  /// 每台可解析主机的凭证 endpoint（`user@host:port`）。解析失败的主机没有 endpoint，
  /// 也就不可能有已保存口令，这不是需要报告的错误。
  static func credentialEndpoints(_ hosts: [SSHHostProfile]) -> [UUID: String] {
    SSHHostResolver.resolveAll(hosts).specs.mapValues(\.credentialEndpoint)
  }

  // MARK: - 排序与候选

  /// 列表顺序：`~/.ssh/config` 导入组在前，其它分组按名称，最后是未分组；组内按名称。
  static func sorted(_ hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    hosts.sorted { lhs, rhs in
      let left = groupRank(lhs.group)
      let right = groupRank(rhs.group)
      if left != right { return left < right }
      if let a = lhs.group, let b = rhs.group, a != b {
        return a.localizedStandardCompare(b) == .orderedAscending
      }
      let order = lhs.name.localizedStandardCompare(rhs.name)
      return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
    }
  }

  /// 分组排名：导入组 0、命名分组 1、未分组 2。
  private static func groupRank(_ group: String?) -> Int {
    guard let group else { return 2 }
    return group == SSHHostProfile.importedGroup ? 0 : 1
  }

  /// 已排序主机里出现过的分组名（去重、保持显示顺序）。
  static func orderedGroups(_ sortedHosts: [SSHHostProfile]) -> [String] {
    var seen: Set<String> = []
    return sortedHosts.compactMap(\.group).filter { seen.insert($0).inserted }
  }

  /// 已排序主机里出现过的标签（不分大小写去重，保留第一次出现的写法与显示顺序）。
  static func orderedTags(_ sortedHosts: [SSHHostProfile]) -> [String] {
    SSHHostStore.normalizedTags(sortedHosts.flatMap { $0.tags ?? [] }) ?? []
  }

  // MARK: - ~/.ssh/config

  /// 生产环境的 `~/.ssh/config` 路径。
  static var sshConfigURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
  }

  /// 确保配置文件存在。已存在的文件（可能是指向 dotfiles 的软链）不改权限、不改内容；
  /// 不存在时先建目录（0700）和空文件（0600）。
  static func ensureSSHConfigFile(at url: URL, fileManager: FileManager = .default) throws {
    guard !fileManager.fileExists(atPath: url.path) else { return }
    let directory = url.deletingLastPathComponent()
    if !fileManager.fileExists(atPath: directory.path) {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    guard fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }

  /// 用系统登记的纯文本编辑器打开文件。`~/.ssh/config` 没有扩展名，直接 `open(url)`
  /// 会找不到默认应用，所以先按纯文本类型查编辑器。
  static func openInDefaultTextEditor(_ url: URL) async throws {
    let workspace = NSWorkspace.shared
    guard let editor = workspace.urlForApplication(toOpen: .plainText) else {
      guard workspace.open(url) else { throw SSHHostEditingError.noTextEditor }
      return
    }
    _ = try await workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
  }

  // MARK: - 错误文案

  /// 把各类错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SSHHostEditingError: return error.message
    case let error as SSHHostDraftError: return error.message
    case SSHHostStoreError.invalidHosts(let reasons):
      return L("主机配置无效：\(reasons.map(friendlyReason).joined(separator: "；"))")
    case SSHHostStoreError.corrupted(let detail): return L("hosts.json 已损坏：\(detail)")
    case SSHHostStoreError.ioFailure(let detail): return L("读写 hosts.json 失败：\(detail)")
    case SSHBrokerError.executableMissing:
      return L("找不到 aster-ssh，请重新构建 Aster.app")
    case SSHBrokerError.startFailed(let detail): return L("aster-ssh 启动失败：\(detail)")
    default: return error.localizedDescription
    }
  }
}
