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

  /// 分组卡片：单击钻进分组，悬停铅笔重命名，右键菜单。导入组不能改名，没有铅笔。
  private func makeGroupCard(_ group: HostBrowserGroup) -> HostsPageCardView {
    let name = group.name
    let content = HostsPageCardContent(
      identifier: "hosts-page-group-\(name)",
      title: name,
      subtitle: L("\(String(group.hostCount)) 台主机"),
      symbol: "square.grid.2x2.fill")
    let editable = name != SSHHostProfile.importedGroup
    return HostsPageCardView(
      content: content, showsTrailingDetail: false,
      onOpen: { [weak self] in self?.enterGroup(name) },
      onEdit: editable ? { [weak self] in self?.promptRenameGroup(name) } : nil,
      editTitle: L("重命名分组…"),
      menuProvider: { [weak self] in self?.makeGroupMenu(name) ?? NSMenu() })
  }

  /// 主机卡片：双击连接，悬停铅笔编辑，右键菜单。采集过系统信息的主机按系统显示图标（Ubuntu 等有自绘标志），
  /// 副标题追加「系统 · 核数 · 内存」，工具提示给完整配置。
  private func makeHostCard(_ host: SSHHostProfile, listMode: Bool) -> HostsPageCardView {
    let id = host.id
    let facts = factsDirectory.facts(for: id)
    var subtitle = HostBrowserCatalog.subtitle(for: host, defaultUser: defaultUser)
    if let facts {
      subtitle += " · " + facts.summary
    } else if factsDirectory.inFlight.contains(id) {
      subtitle += " · " + L("正在采集系统信息…")
    }
    // 被远程开发机器引用的主机打上标注，工具提示列出机器名。
    let machines = editorServices.machines().filter { $0.hostID == id }.map(\.label)
    var toolTip = host.connectString
    if !machines.isEmpty { toolTip += "\n" + L("远程机器：\(machines.joined(separator: "、"))") }
    if let facts { toolTip += "\n" + facts.details }
    let content = HostsPageCardContent(
      identifier: "hosts-page-host-\(id.uuidString)",
      title: HostBrowserCatalog.title(for: host),
      subtitle: subtitle,
      symbol: facts?.family.symbolName ?? SSHHostOSFamily.other.symbolName,
      brand: facts?.brand,
      badge: machines.isEmpty ? nil : L("远程机器"),
      trailingDetail: host.connectString,
      toolTip: toolTip)
    return HostsPageCardView(
      content: content, showsTrailingDetail: listMode, opensOnDoubleClick: true,
      onOpen: { [weak self] in self?.model.openNativeSSH(hostID: id) },
      onEdit: { [weak self] in self?.openEditor(.edit(id)) },
      menuProvider: { [weak self] in self?.makeHostMenu(id) ?? NSMenu() })
  }

  // MARK: - 菜单

  /// 主机卡片的右键菜单：连接 / 编辑… / 复制 / 复制 SSH 命令 / 添加为远程机器… / 删除…。
  func makeHostMenu(_ id: UUID) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionMenuItem(title: L("连接")) { [weak self] in self?.model.openNativeSSH(hostID: id) })
    menu.addItem(ActionMenuItem(title: L("编辑主机…")) { [weak self] in self?.openEditor(.edit(id)) })
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: L("创建副本")) { [weak self] in self?.duplicateHost(id) })
    menu.addItem(ActionMenuItem(title: L("复制 SSH 命令")) { [weak self] in self?.model.copySSHCommand(hostID: id) })
    menu.addItem(ActionMenuItem(title: L("添加为远程机器…")) { [weak self] in self?.deferred { $0.addHostAsMachine(id) } })
    menu.addItem(ActionMenuItem(title: L("刷新系统信息")) { [weak self] in self?.refreshFacts(id) })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("删除主机…")) { [weak self] in
        self?.deferred { page in
          page.confirmAndDeleteHost(id) { [weak page] deleted in
            // 删掉的正是面板里在编辑的主机时，一起关掉面板。
            guard deleted, let page, page.editorPanel?.mode == .edit(id) else { return }
            page.closeEditor()
          }
        }
      })
    return menu
  }

  /// 采集这台主机的系统与硬件信息；结果写进卡片，失败时提示。
  func refreshFacts(_ id: UUID) {
    guard let profile = directory.host(id), !profile.isDefaults else { return }
    let name = HostBrowserCatalog.title(for: profile)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let facts = try await self.factsDirectory.refresh(hostID: id)
        self.model.notice = L("已更新“\(name)”的系统信息：\(facts.summary)")
      } catch let error as SSHHostFactsError {
        self.model.notice = error.message
      } catch {
        self.model.notice = L("采集“\(name)”的系统信息失败：\(SSHHostEditing.describe(error))")
      }
    }
  }

  /// 「新建主机」旁的下拉：新建主机… / 新建分组… / 默认设置… / 从 ~/.ssh/config 导入 / 在 ~/.ssh/config 中编辑。
  func makeNewHostMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ActionMenuItem(title: L("新建主机…")) { [weak self] in self?.createHost() })
    menu.addItem(ActionMenuItem(title: L("新建分组…")) { [weak self] in self?.deferred { $0.promptNewGroup() } })
    menu.addItem(ActionMenuItem(title: L("默认设置…")) { [weak self] in self?.openEditor(.defaults) })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("从 ~/.ssh/config 导入")) { [weak self] in self?.model.importHostsFromSSHConfig() })
    menu.addItem(ActionMenuItem(title: L("在 ~/.ssh/config 中编辑")) { [weak self] in self?.editSSHConfig() })
    return menu
  }

  /// 菜单还在追踪事件时开 sheet 或模态流程会卡住菜单收尾；推到下一轮主循环再执行。
  func deferred(_ action: @escaping (HostsPageViewController) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      action(self)
    }
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
}
