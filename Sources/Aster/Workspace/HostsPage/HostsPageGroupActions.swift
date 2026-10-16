// 主机页对分组的动作：新建、重命名、删除（含确认）与分组卡片的右键菜单。
// 规则在 `SSHHostGrouping`（AsterCore），落盘经 `SSHHostDirectory`；这里只负责表单、确认框与提示。
import AppKit
import AsterCore

extension SSHHostGroupingError {
  /// 给用户看的失败原因。
  var message: String {
    switch self {
    case .emptyName: L("分组名不能为空")
    case .invalidName: L("分组名过长或包含换行")
    case .reserved: L("“\(SSHHostProfile.importedGroup)”是导入组，由导入流程管理，不能新建、改名或删除")
    case .alreadyExists(let name): L("已经有叫“\(name)”的分组")
    case .unknownGroup: L("分组不存在，可能已被删除或改名")
    }
  }
}

extension HostsPageViewController {
  // MARK: - 菜单

  /// 分组卡片的右键菜单：打开 / 重命名分组… / 在此分组新建主机… / 删除分组…。导入组只有打开与新建主机。
  func makeGroupMenu(_ name: String) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionMenuItem(title: L("打开")) { [weak self] in self?.enterGroup(name) })
    let editable = name != SSHHostProfile.importedGroup
    if editable {
      menu.addItem(ActionMenuItem(title: L("重命名分组…")) { [weak self] in self?.deferred { $0.promptRenameGroup(name) } })
    }
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("在此分组新建主机…")) { [weak self] in
        var draft = SSHHostDraft()
        draft.group = name
        self?.openEditor(.new(draft))
      })
    if editable {
      menu.addItem(.separator())
      menu.addItem(ActionMenuItem(title: L("删除分组…")) { [weak self] in self?.deferred { $0.confirmAndDeleteGroup(name) } })
    }
    return menu
  }

  // MARK: - 新建与重命名

  /// 弹出「新建分组」表单，保存后钻进新分组，方便马上往里加主机。
  func promptNewGroup() {
    promptGroupName(
      title: L("新建分组"), message: L("分组只是一个名字；之后新建或编辑主机时选这个分组即可。"),
      initial: "", confirm: L("创建")
    ) { [weak self] name in
      guard let self, let name, self.createGroup(name) else { return }
      self.enterGroup(name)
    }
  }

  /// 弹出「重命名分组」表单。
  func promptRenameGroup(_ old: String) {
    promptGroupName(
      title: L("重命名分组“\(old)”"), message: L("组里的主机会一起改到新分组名下。"),
      initial: old, confirm: L("重命名")
    ) { [weak self] name in
      guard let self, let name else { return }
      _ = self.renameGroup(old, to: name)
    }
  }

  /// 新建空分组；失败时给提示。返回是否成功。
  @discardableResult
  func createGroup(_ name: String) -> Bool {
    do {
      try directory.createGroup(name)
      return true
    } catch {
      model.notice = SSHHostEditing.describe(error)
      return false
    }
  }

  /// 重命名分组；正钻在这一组里时跟着改名。失败时给提示。返回是否成功。
  @discardableResult
  func renameGroup(_ old: String, to new: String) -> Bool {
    do {
      try directory.renameGroup(old, to: new)
      // 正钻在这一组里：目录发布变化时 reload 会发现旧名不存在而退回顶层，所以改完立刻钻进新名。
      if query.group == old { enterGroup(new.trimmingCharacters(in: .whitespacesAndNewlines)) }
      return true
    } catch {
      model.notice = SSHHostEditing.describe(error)
      return false
    }
  }

  // MARK: - 删除

  /// 删除前确认：说明组里的主机会变成未分组、不会被删除；确认后删除。
  func confirmAndDeleteGroup(_ name: String, completion: ((Bool) -> Void)? = nil) {
    let count = directory.savedHosts.filter { $0.group == name }.count
    let alert = NSAlert()
    alert.messageText = L("删除分组“\(name)”？")
    alert.informativeText =
      count == 0
      ? L("这个分组是空的，删除后不再显示。")
      : L("组里的 \(String(count)) 台主机会保留，变成未分组。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("删除"))
    alert.addButton(withTitle: L("取消"))
    present(alert) { [weak self] confirmed in
      guard confirmed, let self else {
        completion?(false)
        return
      }
      completion?(self.deleteGroup(name))
    }
  }

  /// 执行删除；失败时给提示。返回是否成功。
  @discardableResult
  func deleteGroup(_ name: String) -> Bool {
    do {
      try directory.deleteGroup(name)
      return true
    } catch {
      model.notice = SSHHostEditing.describe(error)
      return false
    }
  }

  // MARK: - 表单

  /// 只有一个名称输入框的表单；取消时 `completion` 收到 nil。
  private func promptGroupName(
    title: String, message: String, initial: String, confirm: String, completion: @escaping (String?) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: L("取消"))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.placeholderString = L("分组名")
    field.identifier = NSUserInterfaceItemIdentifier("hosts-page-group-name-field")
    field.setAccessibilityLabel(L("分组名"))
    field.stringValue = initial
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    present(alert) { confirmed in completion(confirmed ? field.stringValue : nil) }
  }
}
