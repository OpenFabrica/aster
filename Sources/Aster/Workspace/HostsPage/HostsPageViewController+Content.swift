// 主机页的卡片内容、右键菜单与工具栏菜单。动作全部转给 `AppModel` 的已有入口。
import AppKit
import AsterCore

extension HostsPageViewController {
  // MARK: - 卡片

  /// 按 `listing` 重建分组卡片与主机卡片。
  func renderCards() {
    let listMode = layoutMode == .list
    groupsGrid.isListMode = listMode
    hostsGrid.isListMode = listMode
    groupsGrid.setItems(listing.groups.map(makeGroupCard))
    hostsGrid.setItems(listing.hosts.map { makeHostCard($0, listMode: listMode) })
    applySectionVisibility(hasGroups: !listing.groups.isEmpty, hasHosts: !listing.hosts.isEmpty)
  }

  /// 分组卡片：点击钻进分组。
  private func makeGroupCard(_ group: HostBrowserGroup) -> HostsPageCardView {
    let content = HostsPageCardContent(
      identifier: "hosts-page-group-\(group.name)",
      title: group.name,
      subtitle: L("\(String(group.hostCount)) 台主机"),
      symbol: "square.grid.2x2.fill")
    return HostsPageCardView(
      content: content, showsTrailingDetail: false,
      onOpen: { [weak self] in self?.enterGroup(group.name) })
  }

  /// 主机卡片：点击连接，悬停铅笔编辑，右键菜单。
  private func makeHostCard(_ host: SSHHostProfile, listMode: Bool) -> HostsPageCardView {
    let id = host.id
    let content = HostsPageCardContent(
      identifier: "hosts-page-host-\(id.uuidString)",
      title: HostBrowserCatalog.title(for: host),
      subtitle: HostBrowserCatalog.subtitle(for: host, defaultUser: defaultUser),
      symbol: "server.rack",
      trailingDetail: host.connectString,
      toolTip: host.connectString)
    return HostsPageCardView(
      content: content, showsTrailingDetail: listMode,
      onOpen: { [weak self] in self?.model.openNativeSSH(hostID: id) },
      onEdit: { [weak self] in self?.model.showHostSettings(hostID: id) },
      menuProvider: { [weak self] in self?.makeHostMenu(id) ?? NSMenu() })
  }

  // MARK: - 菜单

  /// 主机卡片的右键菜单：连接 / 编辑… / 复制 / 复制 SSH 命令 / 删除…。
  func makeHostMenu(_ id: UUID) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionMenuItem(title: L("连接")) { [weak self] in self?.model.openNativeSSH(hostID: id) })
    menu.addItem(ActionMenuItem(title: L("编辑主机…")) { [weak self] in self?.model.showHostSettings(hostID: id) })
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: L("创建副本")) { [weak self] in self?.model.duplicateHost(hostID: id) })
    menu.addItem(ActionMenuItem(title: L("复制 SSH 命令")) { [weak self] in self?.model.copySSHCommand(hostID: id) })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("删除主机…")) { [weak self] in
        guard let self else { return }
        // 菜单还在追踪事件时开 sheet 会卡住菜单收尾；推到下一轮主循环。
        DispatchQueue.main.async { [weak self] in
          self?.model.confirmAndDeleteHost(hostID: id, in: self?.view.window)
        }
      })
    return menu
  }

  /// 「新建主机」旁的下拉：新建主机… / 从 ~/.ssh/config 导入 / 在设置中管理主机…。
  func makeNewHostMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionMenuItem(title: L("新建主机…")) { [weak self] in self?.createHost() })
    menu.addItem(
      ActionMenuItem(title: L("从 ~/.ssh/config 导入")) { [weak self] in self?.model.importHostsFromSSHConfig() })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("在设置中管理主机…")) { [weak self] in self?.model.showHostSettings(hostID: nil) })
    return menu
  }

  /// 标签筛选菜单：「全部标签」+ 已有标签，当前选择打勾。
  func makeTagMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let all = ActionMenuItem(title: L("全部标签")) { [weak self] in self?.setTagFilter(nil) }
    all.state = query.tag == nil ? .on : .off
    menu.addItem(all)
    let tags = HostBrowserCatalog.tags(in: directory.hosts)
    if tags.isEmpty {
      let none = NSMenuItem(title: L("还没有标签"), action: nil, keyEquivalent: "")
      none.isEnabled = false
      menu.addItem(none)
      return menu
    }
    menu.addItem(.separator())
    for tag in tags {
      let item = ActionMenuItem(title: "#\(tag)") { [weak self] in self?.setTagFilter(tag) }
      item.state = query.tag?.caseInsensitiveCompare(tag) == .orderedSame ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  /// 排序菜单：名称 A–Z / 最近使用。
  func makeSortMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (sort, title) in [(HostBrowserSort.name, L("名称 A–Z")), (.recent, L("最近使用"))] {
      let item = ActionMenuItem(title: title) { [weak self] in self?.setSort(sort) }
      item.state = query.sort == sort ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  // MARK: - 动作

  /// 新建主机：搜索框里是地址时预填它；钻在分组里时预填该分组。保存后可选立即连接。
  func createHost() {
    let typed = QuickConnectTarget.looksLikeTarget(query.search)
      ? QuickConnectTarget.parse(query.search) : nil
    let prefill = SaveSSHHostSheet.Prefill(
      name: typed?.host ?? "", group: query.group,
      target: typed ?? QuickConnectTarget(user: nil, host: "", port: nil))
    let window = view.window
    // 按钮回调里直接开模态表单会打断按钮自身的事件收尾；推到下一轮主循环。
    DispatchQueue.main.async { [weak self] in
      self?.model.presentSaveHost(prefill: prefill, title: L("新建主机"), in: window)
    }
  }
}
