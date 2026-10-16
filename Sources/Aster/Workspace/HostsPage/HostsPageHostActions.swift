// 主机页对单台主机的动作：复制、删除（含影响确认）、忘记口令、添加为远程机器、编辑 ~/.ssh/config。
// 规则都在 `SSHHostEditing` / `SSHHostRemoval`；这里只负责确认框、依赖注入与结果提示。
import AppKit
import AsterCore
import Combine

/// 主机页动作的外部依赖。生产用 `.live()`；测试注入假钥匙串、空机器列表与桩编辑器。
struct HostsPageEditorServices {
  /// 保险库密钥当前列表（编辑面板的勾选项）。
  var vaultKeys: @MainActor () -> [SSHVaultKey]
  /// 口令钥匙串；查询在后台执行，删除在用户确认后执行。
  var credentials: any SSHCredentialStoring
  /// 当前机器配置：卡片据此标注「远程机器」，删除确认里列出引用它的机器。
  var machines: @MainActor () -> [MachineProfile]
  /// 机器列表将要变化的通知，主机页据此重画标注；默认不通知（测试）。
  var machinesChanged: @MainActor () -> AnyPublisher<Void, Never> = { Empty().eraseToAnyPublisher() }
  /// 弹出「添加机器」流程。
  var addMachine: @MainActor (MachineSetupFlow.Prefill, NSWindow?) -> Void
  var sshConfigURL: URL
  /// 用默认文本编辑器打开文件。
  var openInEditor: @MainActor (URL) async throws -> Void

  /// 生产依赖：共享保险库、真实钥匙串、机器编队与系统文本编辑器。
  @MainActor static func live() -> HostsPageEditorServices {
    HostsPageEditorServices(
      vaultKeys: { SSHVaultKeyDirectory.shared.keys },
      credentials: SSHCredentialStore(),
      machines: { MachineFleetModel.shared.profiles },
      machinesChanged: { MachineFleetModel.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher() },
      addMachine: { prefill, window in
        Task { @MainActor in _ = await MachineSetupFlow.presentAddMachine(prefill: prefill, in: window) }
      },
      sshConfigURL: SSHHostEditing.sshConfigURL,
      openInEditor: SSHHostEditing.openInDefaultTextEditor)
  }
}

/// 把 `SSHCredentialStoring` 适配成删除与忘记口令用的 `SSHHostPasswordStore`。
@MainActor
struct HostsPageCredentialPasswords: SSHHostPasswordStore {
  let credentials: any SSHCredentialStoring

  func hasPassword(for endpoint: String) -> Bool { credentials.hasPassword(for: endpoint) }
  func deletePassword(for endpoint: String) throws { try credentials.deletePassword(for: endpoint) }
}

extension HostsPageViewController {
  // MARK: - 复制与删除

  /// 复制一台主机，返回副本；失败时给提示。
  @discardableResult
  func duplicateHost(_ id: UUID) -> SSHHostProfile? {
    do {
      return try SSHHostEditing.duplicate(id, in: directory)
    } catch {
      model.notice = SSHHostEditing.describe(error)
      return nil
    }
  }

  /// 删除前确认：列出引用它的机器、用它作跳板的主机与口令去留；确认后删除。
  ///
  /// 口令状态要查钥匙串，先在后台查完再弹确认框。`completion` 收到是否真的删除了。
  func confirmAndDeleteHost(_ id: UUID, completion: ((Bool) -> Void)? = nil) {
    guard let profile = directory.host(id), !profile.isDefaults else {
      completion?(false)
      return
    }
    let impact = SSHHostEditing.deletionImpact(
      of: id, hosts: directory.hosts, machines: editorServices.machines())
    Task { @MainActor [weak self] in
      guard let self else { return }
      let hasPassword = await self.lookupPassword(hostID: id)
      let alert = NSAlert()
      alert.messageText = L("删除主机“\(HostBrowserCatalog.title(for: profile))”？")
      // 远程开发机器连的就是这台主机：删除前把后果说在最前面，而不是只在列表里带一笔。
      let machineNote: String? =
        impact.machines.isEmpty
        ? nil
        : L("这台主机是远程机器“\(impact.machines.joined(separator: "、"))”的连接目标，删除后这些机器无法再连接。")
      let passwordNote: String? =
        hasPassword
        ? (impact.credentialSharedWith.isEmpty
          ? L("已保存的口令会一起从钥匙串删除。") : L("已保存的口令还被其它主机使用，会保留在钥匙串里。"))
        : nil
      alert.informativeText = Self.confirmationText(
        body: [machineNote, L("删除后不能撤销。"), passwordNote].compactMap { $0 }.joined(separator: " "),
        lists: [
          (L("引用它的机器（\(String(impact.machines.count))）："), impact.machines),
          (L("用它作跳板的主机（\(String(impact.jumpDependents.count))），删除后不再经过跳板："), impact.jumpDependents),
          (L("共用同一口令的主机："), hasPassword ? impact.credentialSharedWith : []),
        ])
      alert.alertStyle = .warning
      alert.addButton(withTitle: L("删除"))
      alert.addButton(withTitle: L("取消"))
      self.present(alert) { [weak self] confirmed in
        guard confirmed, let self else {
          completion?(false)
          return
        }
        completion?(self.deleteHost(id))
      }
    }
  }

  /// 执行删除；口令清理失败只提示，主机列表由目录发布的变化自动刷新。返回主机是否已删除。
  private func deleteHost(_ id: UUID) -> Bool {
    do {
      let passwords = HostsPageCredentialPasswords(credentials: editorServices.credentials)
      if let passwordError = try SSHHostRemoval.remove(id, from: directory, passwords: passwords) {
        model.notice = L("主机已删除，但没能从钥匙串删除口令：\(SSHHostEditing.describe(passwordError))")
      }
      return true
    } catch {
      model.notice = SSHHostEditing.describe(error)
      return false
    }
  }

  // MARK: - 口令

  /// 这台主机的 endpoint 是否保存了口令；钥匙串查询放到后台，主机无法解析时为 false。
  func lookupPassword(hostID: UUID) async -> Bool {
    guard let endpoint = SSHHostEditing.credentialEndpoints(directory.hosts)[hostID] else { return false }
    let credentials = editorServices.credentials
    return await Task.detached { credentials.hasPassword(for: endpoint) }.value
  }

  /// 忘记口令前确认，并列出共用同一口令、会一起失效的主机。`completion` 收到是否已忘记。
  func confirmAndForgetPassword(_ id: UUID, completion: ((Bool) -> Void)? = nil) {
    guard let profile = directory.host(id), !profile.isDefaults else {
      completion?(false)
      return
    }
    let shared = SSHHostStore.hostsSharingCredential(with: id, in: directory.hosts).map(\.name)
    let alert = NSAlert()
    alert.messageText = L("忘记“\(profile.name)”的口令？")
    alert.informativeText = Self.confirmationText(
      body: L("口令会从钥匙串删除，下次连接时重新询问。"),
      lists: [(L("以下主机用同一个口令，也会一起失效："), shared)])
    alert.addButton(withTitle: L("忘记口令"))
    alert.addButton(withTitle: L("取消"))
    present(alert) { [weak self] confirmed in
      guard confirmed, let self else {
        completion?(false)
        return
      }
      do {
        let passwords = HostsPageCredentialPasswords(credentials: self.editorServices.credentials)
        try SSHHostEditing.forgetPassword(id, in: self.directory, passwords: passwords)
        self.model.notice = L("已忘记“\(profile.name)”的口令")
        completion?(true)
      } catch {
        self.model.notice = SSHHostEditing.describe(error)
        completion?(false)
      }
    }
  }

  // MARK: - 添加为机器与 ~/.ssh/config

  /// 以这台主机为预填值弹出「添加机器」流程。
  func addHostAsMachine(_ id: UUID) {
    guard let profile = directory.host(id), !profile.isDefaults else { return }
    editorServices.addMachine(MachineSetupFlow.Prefill(label: profile.name, hostID: profile.id), view.window)
  }

  /// 用默认编辑器打开 `~/.ssh/config`；文件不存在时先建好。
  func editSSHConfig() {
    let url = editorServices.sshConfigURL
    do {
      try SSHHostEditing.ensureSSHConfigFile(at: url)
    } catch {
      model.notice = L("无法创建 ~/.ssh/config：\(SSHHostEditing.describe(error))")
      return
    }
    let open = editorServices.openInEditor
    Task { @MainActor [weak self] in
      do {
        try await open(url)
      } catch {
        self?.model.notice = L("无法打开 ~/.ssh/config：\(SSHHostEditing.describe(error))")
      }
    }
  }

  // MARK: - 确认框

  /// 以窗口 sheet 弹出确认框（没有窗口时模态）；第一个按钮表示确认。
  func present(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
    if let window = view.window {
      alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    } else {
      completion(alert.runModal() == .alertFirstButtonReturn)
    }
  }

  /// 确认框正文：一段说明 + 若干「标题 + 列表」，空列表省略。
  static func confirmationText(body: String, lists: [(String, [String])]) -> String {
    var parts = [body]
    for (heading, items) in lists where !items.isEmpty {
      parts.append(([heading] + items.map { "• \($0)" }).joined(separator: "\n"))
    }
    return parts.joined(separator: "\n\n")
  }
}
