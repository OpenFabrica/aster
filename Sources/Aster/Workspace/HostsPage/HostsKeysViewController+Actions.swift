// 「密钥」子页的动作编排：右键菜单、详情面板按钮与工具栏按钮共用这些入口。
// 先用对话框确认或收集输入，再调用 `SSHVaultKeyActions`；校验与安全规则都在服务里。
import AppKit
import AsterCore

extension HostsKeysViewController {
  // MARK: - 菜单

  /// 一把密钥的右键菜单：复制公钥 / 重命名… / 改用保险库密钥… / 删除原文件… / 删除…。
  func makeKeyMenu(_ id: UUID) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    guard let row = rows.first(where: { $0.id == id }) else { return menu }
    /// 菜单还在追踪事件时开 sheet 会卡住菜单收尾；动作推到下一轮主循环。
    func item(_ title: String, enabled: Bool = true, _ action: @escaping (HostsKeysViewController) -> Void) {
      let entry = ActionMenuItem(title: title) { [weak self] in
        DispatchQueue.main.async { [weak self] in if let self { action(self) } }
      }
      entry.isEnabled = enabled
      menu.addItem(entry)
    }
    item(L("复制公钥")) { $0.copyPublicKey(id) }
    item(L("重命名…")) { $0.renameKey(id) }
    if !row.migratableHosts.isEmpty {
      item(L("改用保险库密钥（\(String(row.migratableHosts.count)) 台主机）…")) { $0.migrateReferences(id) }
    }
    // 服务会弹出自己的确认框，列出全部后果后才删除，这里不再重复确认。
    if row.canDeleteOriginal {
      item(L("删除原文件…"), enabled: !actions.isBusy) { $0.deleteOriginal(id) }
    }
    menu.addItem(.separator())
    item(L("删除…"), enabled: !actions.isBusy) { $0.deleteKey(id) }
    return menu
  }

  /// 详情面板按钮的动作；面板只在有选中的密钥时可见。
  func makeDetailHandlers() -> HostsKeyDetailView.Handlers {
    /// 对当前选中的密钥执行动作。
    func onSelected(_ action: @escaping (HostsKeysViewController, UUID) -> Void) -> () -> Void {
      { [weak self] in
        guard let self, let id = self.selectedID else { return }
        // 按钮回调里直接开 sheet 会打断按钮自身的事件收尾；推到下一轮主循环。
        DispatchQueue.main.async { [weak self] in if let self { action(self, id) } }
      }
    }
    return HostsKeyDetailView.Handlers(
      copyPublicKey: onSelected { $0.copyPublicKey($1) },
      rename: onSelected { $0.renameKey($1) },
      migrate: onSelected { $0.migrateReferences($1) },
      deleteOriginal: onSelected { $0.deleteOriginal($1) },
      delete: onSelected { $0.deleteKey($1) },
      close: { [weak self] in self?.select(nil) })
  }

  // MARK: - 动作

  /// 导入私钥文件；成功后选中新导入（或已存在）的那把密钥。
  func importKey() {
    guard !actions.isBusy else { return }
    let before = Set(actions.directory.keys.map(\.id))
    Task { @MainActor [weak self] in
      guard let self, await self.actions.importKey() else { return }
      self.selectNewest(excluding: before)
    }
  }

  /// 生成新密钥：输入名称与注释；服务拒绝时带着原因和原输入重新弹出表单，直到成功或取消。
  func generateKey() {
    guard !actions.isBusy else { return }
    Task { @MainActor [weak self] in
      var request = HostsKeyNameRequest(mode: .generate)
      while let self, let result = await self.prompts.name(request, self.view.window) {
        let before = Set(self.actions.directory.keys.map(\.id))
        self.lastError = nil
        if await self.actions.generate(label: result.label, comment: result.comment) {
          self.selectNewest(excluding: before)
          return
        }
        // 没有错误说明是被进行中的动作挡住（isBusy），不再重复弹表单。
        guard let error = self.lastError else { return }
        request = HostsKeyNameRequest(mode: .generate, label: result.label, comment: result.comment, error: error)
      }
    }
  }

  /// 重命名：预填当前名称；失败时带原因重新弹出。
  func renameKey(_ id: UUID) {
    guard let current = actions.directory.key(id) else { return }
    Task { @MainActor [weak self] in
      var request = HostsKeyNameRequest(mode: .rename, label: current.label)
      while let self, let result = await self.prompts.name(request, self.view.window) {
        self.lastError = nil
        if self.actions.rename(id, label: result.label) { return }
        guard let error = self.lastError else { return }
        request = HostsKeyNameRequest(mode: .rename, label: result.label, error: error)
      }
    }
  }

  /// 复制公钥到剪贴板。
  func copyPublicKey(_ id: UUID) {
    _ = actions.copyPublicKey(id)
  }

  /// 确认后把仍指向原文件的主机改用这把保险库密钥。
  func migrateReferences(_ id: UUID) {
    guard let row = rows.first(where: { $0.id == id }), !row.migratableHosts.isEmpty else { return }
    Task { @MainActor [weak self] in
      guard let self, await self.prompts.confirmMigrate(row, self.view.window) else { return }
      _ = self.actions.migrateReferences(id)
    }
  }

  /// 删除原私钥文件；核对与确认都在服务里。
  func deleteOriginal(_ id: UUID) {
    Task { @MainActor [weak self] in _ = await self?.actions.deleteOriginal(id) }
  }

  /// 确认后删除密钥（目录、钥匙串与主机引用一起清理）。
  func deleteKey(_ id: UUID) {
    guard let row = rows.first(where: { $0.id == id }) else { return }
    Task { @MainActor [weak self] in
      guard let self, await self.prompts.confirmDelete(row, self.view.window) else { return }
      if await self.actions.delete(id), self.selectedID == id { self.select(nil) }
    }
  }

  /// 选中动作之后出现的新密钥；没有新密钥（导入了已有的同一把）时保持原选择。
  private func selectNewest(excluding before: Set<UUID>) {
    guard let added = actions.directory.keys.first(where: { !before.contains($0.id) }) else {
      reload()
      return
    }
    select(added.id)
  }
}
