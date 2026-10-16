import AppKit
import AsterCore
import Foundation

// 「主机」分类的动作：保存、复制、删除、忘记口令、添加为机器、导入与编辑 ~/.ssh/config。
// 每个动作都以 `complete(succeeded)` 结束，SettingsViewController 据此给网页发回执。

/// 主机动作失败的原因；定义已移到 `SSHHostEditingError`，保留旧名供既有调用方使用。
typealias SettingsHostsError = SSHHostEditingError

extension SettingsHostsBridge {
  /// 网页回传的主机对象最大字节数；远大于任何正常配置，只挡异常输入。
  static let maximumPayloadBytes = 64 * 1024
  static let maximumForwards = SSHHostEditRules.maximumForwards
  /// 私钥文件与 known_hosts 文件各自的最多行数。
  static let maximumIdentityFiles = SSHHostEditRules.maximumIdentityFiles

  /// 分发一个 `hosts.` 前缀的动作。未知动作 toast 报错并回执失败。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    switch action {
    case "hosts.save": save(payload, complete: complete)
    case "hosts.duplicate": duplicate(payload, complete: complete)
    case "hosts.delete": delete(payload, complete: complete)
    case "hosts.forgetPassword": forgetPassword(payload, complete: complete)
    case "hosts.addMachine": addMachine(payload, complete: complete)
    case "hosts.import": importSSHConfig(complete: complete)
    case "hosts.editSSHConfig": editSSHConfig(complete: complete)
    case _ where action.hasPrefix("hosts.keys.") && keysBridge != nil:
      keysBridge?.handle(action: action, payload: payload, complete: complete)
    case _ where SettingsAgentAccessBridge.actions.contains(action):
      agentAccess.handle(action: action, payload: payload, complete: complete)
    default:
      // `hosts.knownHosts.*` 交给「已知主机」协作者；它不认识的才算未知动作。
      guard !knownHosts.handle(action: action, payload: payload, complete: complete) else { return }
      toast(L("“\(action)”尚无可用的 macOS 操作"), true)
      complete(false)
    }
  }

  // MARK: - 保存

  /// 新增或更新一台主机（含默认项）。清理、校验与落盘都在 `SSHHostEditing.save`，失败时 toast 原因且不落盘。
  private func save(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      try SSHHostEditing.save(try Self.decodeProfile(payload["profile"]), in: directory)
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  /// 解码网页回传的主机对象：先挡超大 payload，再按 `SSHHostEditing.sanitize` 做边界清理。
  static func decodeProfile(_ raw: Any?) throws -> SSHHostProfile {
    guard let object = raw as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
      throw SettingsHostsError.invalidPayload
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    guard data.count <= maximumPayloadBytes else { throw SettingsHostsError.invalidPayload }
    let profile: SSHHostProfile
    do { profile = try JSONDecoder().decode(SSHHostProfile.self, from: data) } catch {
      throw SettingsHostsError.invalidPayload
    }
    return try SSHHostEditing.sanitize(profile)
  }

  /// 校验候选列表；规则在 `SSHHostEditing.validate`。
  static func validate(_ profile: SSHHostProfile, in candidate: [SSHHostProfile]) throws {
    try SSHHostEditing.validate(profile, in: candidate)
  }

  /// 存储校验原因的中文说明；规则在 `SSHHostEditing.friendlyReason`。
  static func friendlyReason(_ reason: String) -> String {
    SSHHostEditing.friendlyReason(reason)
  }

  // MARK: - 复制、删除、忘记口令

  /// 复制一台主机；规则在 `SSHHostEditing.duplicate`。
  private func duplicate(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      try SSHHostEditing.duplicate(try savedHost(payload).id, in: directory)
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  /// 删除一台主机。只有没有其它主机共用同一 endpoint 时，才顺带删掉钥匙串里的口令。
  private func delete(_ payload: [String: Any], complete: (Bool) -> Void) {
    let profile: SSHHostProfile
    do { profile = try savedHost(payload) } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    let passwordError: (any Error)?
    do {
      passwordError = try SSHHostRemoval.remove(
        profile.id, from: directory, passwords: dependencies.passwords)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    if let passwordError {
      toast(L("主机已删除，但没能从钥匙串删除口令：\(Self.describe(passwordError))"), true)
    }
    pushSnapshot()
    complete(true)
  }

  /// 忘记这台主机 endpoint 的口令。共用 endpoint 的主机会一起失去口令，确认框已提示。
  private func forgetPassword(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let profile = try savedHost(payload)
      try SSHHostEditing.forgetPassword(profile.id, in: directory, passwords: dependencies.passwords)
      toast(L("已忘记“\(profile.name)”的口令"), false)
      pushSnapshot()
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  // MARK: - 添加为机器

  /// 以这台主机为预填值弹出「添加机器」流程。流程本身异步，回执只表示已经弹出。
  private func addMachine(_ payload: [String: Any], complete: (Bool) -> Void) {
    do {
      let profile = try savedHost(payload)
      dependencies.addMachine(
        MachineSetupFlow.Prefill(label: profile.name, hostID: profile.id), window())
      complete(true)
    } catch {
      toast(Self.describe(error), true)
      complete(false)
    }
  }

  // MARK: - ~/.ssh/config

  /// 从 `~/.ssh/config` 导入：合并进导入组，保存后把汇总发给网页显示。
  private func importSSHConfig(complete: @escaping (Bool) -> Void) {
    guard !isImporting else {
      complete(false)
      return
    }
    isImporting = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isImporting = false }
      do {
        let listing = try await self.dependencies.configListing()
        let result = try self.directory.mergeSSHConfig(listing)
        self.postMessage(["type": "hostsImportReport", "report": Self.reportJSON(result)])
        self.pushSnapshot()
        complete(true)
      } catch {
        self.toast(L("无法导入 ~/.ssh/config：\(Self.describe(error))"), true)
        complete(false)
      }
    }
  }

  /// 导入汇总的网页形状。
  static func reportJSON(_ result: SSHConfigImportResult) -> [String: Any] {
    [
      "added": result.added,
      "updated": result.updated,
      "unchanged": result.unchanged,
      "ignored": result.ignored.map {
        ["file": $0.file, "line": $0.line, "option": $0.option, "reason": $0.reason] as [String: Any]
      },
      "unresolvedJumps": result.unresolvedJumps.map { ["host": $0.host, "proxyJump": $0.proxyJump] },
      "rejected": result.rejected.map {
        ["alias": $0.alias, "reasons": $0.reasons.map(friendlyReason)] as [String: Any]
      },
    ]
  }

  /// 用默认编辑器打开 `~/.ssh/config`；文件不存在时先建目录（0700）和空文件（0600）。
  private func editSSHConfig(complete: @escaping (Bool) -> Void) {
    let url = dependencies.sshConfigURL
    do {
      try Self.ensureSSHConfigFile(at: url)
    } catch {
      toast(L("无法创建 ~/.ssh/config：\(Self.describe(error))"), true)
      complete(false)
      return
    }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.dependencies.openInEditor(url)
        complete(true)
      } catch {
        self.toast(L("无法打开 ~/.ssh/config：\(Self.describe(error))"), true)
        complete(false)
      }
    }
  }

  /// 确保配置文件存在；规则在 `SSHHostEditing.ensureSSHConfigFile`。
  static func ensureSSHConfigFile(at url: URL, fileManager: FileManager = .default) throws {
    try SSHHostEditing.ensureSSHConfigFile(at: url, fileManager: fileManager)
  }

  // MARK: - 工具

  /// 按 payload 里的 `id` 找一台已保存主机（不含默认项）。
  private func savedHost(_ payload: [String: Any]) throws -> SSHHostProfile {
    guard let raw = payload["id"] as? String, let id = UUID(uuidString: raw) else {
      throw SettingsHostsError.invalidPayload
    }
    guard let profile = directory.host(id), !profile.isDefaults else {
      throw SettingsHostsError.unknownHost
    }
    return profile
  }

  /// 把各类错误转成一句给用户看的话；规则在 `SSHHostEditing.describe`。
  static func describe(_ error: Error) -> String { SSHHostEditing.describe(error) }
}
