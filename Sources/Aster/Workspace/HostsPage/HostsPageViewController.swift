// 侧栏「主机」页：搜索/快连框、工具栏、分组卡片与主机卡片。占据工作区内容区，
// 选中任何标签即回到终端（见 `AppModel.isHostsPagePresented`）。
import AppKit
import AsterCore
import Combine

/// 主机页控制器。工作区控制器跨整树刷新复用同一实例，搜索词、钻取的分组与滚动位置都保留。
///
/// 主机数据只从 `SSHHostDirectory` 读，增删改都走目录或 `AppModel` 的已有入口，
/// 这里不持有可写副本；目录发布变化时重算卡片。
@MainActor
final class HostsPageViewController: NSViewController, NSTextFieldDelegate {
  /// 卡片排布方式。
  enum LayoutMode {
    case grid
    case list
  }

  let model: AppModel
  let directory: SSHHostDirectory
  /// 读使用账本；测试注入固定账本，避免读写用户真实偏好。
  private let usageLedger: () -> HostUsageLedger
  /// 主机没写用户名时显示的用户名：默认项的用户名，再缺省为本机用户。
  private let localUser: String

  private(set) var query = HostBrowserQuery()
  private(set) var layoutMode: LayoutMode = .grid
  /// 最近一次计算出的卡片数据，供回车连接与测试读取。
  private(set) var listing = HostBrowserListing(groups: [], hosts: [])

  let searchField = NSTextField()
  private(set) var connectButton: HostsPagePillButton!
  private let breadcrumb = NSStackView()
  private let breadcrumbTitle = makeLabel("", size: 13, weight: .semibold, color: AsterTheme.ink)
  private let groupsTitle = makeHostsPageSectionTitle(L("分组"), identifier: "hosts-page-groups-title")
  private let hostsTitle = makeHostsPageSectionTitle(L("主机"), identifier: "hosts-page-hosts-title")
  let groupsGrid = HostsPageGridView(rowHeight: InterfaceScale.length(HostsPageCardView.height))
  let hostsGrid = HostsPageGridView(rowHeight: InterfaceScale.length(HostsPageCardView.height))
  private let emptyLabel = makeLabel("", size: 12.5, color: AsterTheme.secondaryInk)
  private let scrollView = NSScrollView()
  private let searchBar = HostsPageFilledView(fillColor: HostsPagePalette.control, cornerRadius: 9)
  private var layoutToggle: HostsPagePillButton!
  private var tagButton: HostsPagePillButton!
  private var cancellables: Set<AnyCancellable> = []

  /// 生产用共享主机目录与真实使用账本；测试注入临时目录与固定账本。
  init(
    model: AppModel, directory: SSHHostDirectory = .shared,
    usageLedger: @escaping () -> HostUsageLedger = { HostUsageTracking.ledger() },
    localUser: String = NSUserName()
  ) {
    self.model = model
    self.directory = directory
    self.usageLedger = usageLedger
    self.localUser = localUser
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("hosts-page")
    view = root
    buildLayout(in: root)
    // @Published 在 willSet 时发出，此刻 `hosts` 还是旧值；切到下一轮主队列再读。
    directory.$hosts
      .map { _ in () }
      .merge(with: directory.$loadError.map { _ in () })
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.reload() }
      .store(in: &cancellables)
    reload()
  }

  /// 每次挂到内容区时调用：刷新「最近使用」依据，并把键盘焦点交给搜索框。
  func pageDidAppear() {
    // 主题可能在页面隐藏期间换过：底色视图重画，卡片在 reload 里按新主题重建。
    searchBar.needsDisplay = true
    reload()
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.view.window else { return }
      window.makeFirstResponder(self.searchField)
    }
  }

  // MARK: - 布局

  /// 搭建固定的页面骨架；卡片内容由 `reload()` 填充。标题带由外壳 `HostsHubViewController` 提供。
  private func buildLayout(in root: NSView) {
    let searchBar = makeSearchBar()
    let toolbar = makeToolbar()
    configureBreadcrumb()
    configureScrollView()
    for subview in [searchBar, toolbar, scrollView] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(subview)
    }
    let inset: CGFloat = 24
    NSLayoutConstraint.activate([
      searchBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
      searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

      toolbar.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 14),
      toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
      toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

      scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  /// 顶部宽搜索框：放大镜 + 输入框 + 右端「连接」按钮。
  private func makeSearchBar() -> NSView {
    let bar = searchBar
    bar.identifier = NSUserInterfaceItemIdentifier("hosts-page-search-bar")
    bar.heightAnchor.constraint(equalToConstant: InterfaceScale.length(40)).isActive = true

    let glass = NSImageView()
    glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(13), weight: .medium))
    glass.contentTintColor = AsterTheme.tertiaryInk
    glass.translatesAutoresizingMaskIntoConstraints = false

    searchField.identifier = NSUserInterfaceItemIdentifier("hosts-page-search-field")
    searchField.placeholderString = L("查找主机或 ssh user@hostname…")
    searchField.isBordered = false
    searchField.drawsBackground = false
    searchField.focusRingType = .none
    searchField.font = NSFont.interface(ofSize: 14)
    searchField.textColor = AsterTheme.ink
    searchField.delegate = self
    searchField.cell?.isScrollable = true
    searchField.cell?.wraps = false
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.setAccessibilityLabel(L("查找主机或 ssh user@hostname…"))

    connectButton = HostsPagePillButton(title: L("连接"), symbol: nil, showsBackground: true) {
      [weak self] in self?.connectFromSearch()
    }
    connectButton.identifier = NSUserInterfaceItemIdentifier("hosts-page-connect-button")
    for subview in [glass, searchField, connectButton!] as [NSView] { bar.addSubview(subview) }
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 13),
      glass.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 9),
      searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      searchField.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -10),
      connectButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -5),
      connectButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
    ])
    return bar
  }

  /// 工具栏：新建主机（含下拉）、终端；右侧是布局切换、标签筛选与排序。
  private func makeToolbar() -> NSView {
    let newHost = HostsPagePillButton(title: L("新建主机"), symbol: "plus") { [weak self] in
      self?.createHost()
    }
    newHost.identifier = NSUserInterfaceItemIdentifier("hosts-page-new-host")
    let more = HostsPagePillButton(
      title: "", symbol: "chevron.down", menuProvider: { [weak self] in self?.makeNewHostMenu() ?? NSMenu() })
    more.identifier = NSUserInterfaceItemIdentifier("hosts-page-new-host-menu")
    more.toolTip = L("更多新建选项")
    let terminal = HostsPagePillButton(title: L("终端"), symbol: "apple.terminal", showsBackground: false) {
      [weak self] in self?.model.newTab()
    }
    terminal.identifier = NSUserInterfaceItemIdentifier("hosts-page-terminal")
    terminal.toolTip = L("新建本机终端标签")

    layoutToggle = HostsPagePillButton(title: "", symbol: "square.grid.2x2", showsBackground: false) {
      [weak self] in self?.toggleLayoutMode()
    }
    layoutToggle.identifier = NSUserInterfaceItemIdentifier("hosts-page-layout-toggle")
    tagButton = HostsPagePillButton(
      title: "", symbol: "tag", showsBackground: false,
      menuProvider: { [weak self] in self?.makeTagMenu() ?? NSMenu() })
    tagButton.identifier = NSUserInterfaceItemIdentifier("hosts-page-tag-filter")
    let sort = HostsPagePillButton(
      title: "", symbol: "arrow.up.arrow.down", showsBackground: false,
      menuProvider: { [weak self] in self?.makeSortMenu() ?? NSMenu() })
    sort.identifier = NSUserInterfaceItemIdentifier("hosts-page-sort")
    sort.toolTip = L("排序")

    let leading = NSStackView(views: [newHost, more])
    leading.spacing = 2
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [leading, terminal, spacer, layoutToggle, tagButton, sort])
    row.orientation = .horizontal
    row.spacing = 10
    row.setCustomSpacing(4, after: layoutToggle)
    row.setCustomSpacing(4, after: tagButton)
    updateToolbarState()
    return row
  }

  /// 钻进分组后显示的面包屑：「‹ 主机 / 分组名」。
  private func configureBreadcrumb() {
    let back = HostsPagePillButton(title: L("主机"), symbol: "chevron.left", showsBackground: false) {
      [weak self] in self?.leaveGroup()
    }
    back.identifier = NSUserInterfaceItemIdentifier("hosts-page-breadcrumb-back")
    let slash = makeLabel("/", size: 13, color: AsterTheme.tertiaryInk)
    breadcrumbTitle.identifier = NSUserInterfaceItemIdentifier("hosts-page-breadcrumb-title")
    breadcrumb.setViews([back, slash, breadcrumbTitle], in: .leading)
    breadcrumb.orientation = .horizontal
    breadcrumb.spacing = 6
    breadcrumb.identifier = NSUserInterfaceItemIdentifier("hosts-page-breadcrumb")
  }

  /// 卡片区：透明滚动视图 + 上下排列的分区。面包屑放在同一个栈里，隐藏时不占高度。
  private func configureScrollView() {
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = document

    emptyLabel.identifier = NSUserInterfaceItemIdentifier("hosts-page-empty")
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.maximumNumberOfLines = 0
    let stack = NSStackView(views: [breadcrumb, groupsTitle, groupsGrid, hostsTitle, hostsGrid, emptyLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.setCustomSpacing(30, after: groupsGrid)
    stack.setCustomSpacing(18, after: breadcrumb)
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    let clip = scrollView.contentView
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
      groupsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      hostsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  // MARK: - 搜索框

  /// 输入即过滤。
  func controlTextDidChange(_ obj: Notification) {
    query.search = searchField.stringValue
    reload()
  }

  /// 回车连接；Esc 先清空搜索词，再退出分组。
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      connectFromSearch()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      if !searchField.stringValue.isEmpty {
        searchField.stringValue = ""
        query.search = ""
        reload()
      } else if query.group != nil {
        leaveGroup()
      }
      return true
    default:
      return false
    }
  }

  /// 按搜索框当前内容连接：已保存主机走主机配置，地址走临时连接。
  func connectFromSearch() {
    switch HostBrowserCatalog.connectIntent(
      query: query.search, hosts: directory.hosts, visible: listing.hosts)
    {
    case .host(let id)?: model.openNativeSSH(hostID: id)
    case .target(let target)?: model.openNativeSSH(target: target.normalizedTarget)
    case nil: NSSound.beep()
    }
  }

  // MARK: - 状态变化

  /// 钻进某个分组。搜索词保留：用户可能就是想在这一组里继续找。
  func enterGroup(_ name: String) {
    query.group = name
    reload()
    scrollView.contentView.scroll(to: .zero)
  }

  /// 回到顶层。
  func leaveGroup() {
    query.group = nil
    reload()
  }

  /// 网格 ↔ 列表。
  func toggleLayoutMode() {
    layoutMode = layoutMode == .grid ? .list : .grid
    reload()
  }

  /// 切换标签筛选；nil 表示全部标签。
  func setTagFilter(_ tag: String?) {
    query.tag = tag
    reload()
  }

  /// 切换排序方式。
  func setSort(_ sort: HostBrowserSort) {
    query.sort = sort
    reload()
  }

  /// 按当前条件重算卡片并更新面包屑、连接按钮与空状态。
  func reload() {
    guard isViewLoaded else { return }
    // 钻进的分组被删空或改名后自动回到顶层，不留一个永远空白的分组页。
    if let group = query.group, !directory.savedHosts.contains(where: { $0.group == group }) {
      query.group = nil
    }
    listing = HostBrowserCatalog.listing(
      hosts: directory.hosts, query: query, lastUsed: usageLedger().lastUsedByID)
    renderCards()
    breadcrumb.isHidden = query.group == nil
    breadcrumbTitle.stringValue = query.group ?? ""
    connectButton.isEnabled =
      HostBrowserCatalog.connectIntent(query: query.search, hosts: directory.hosts, visible: listing.hosts) != nil
    connectButton.alphaValue = connectButton.isEnabled ? 1 : 0.45
    updateToolbarState()
  }

  /// 工具栏按钮的图标与提示跟随当前状态。
  private func updateToolbarState() {
    layoutToggle?.image = NSImage(
      systemSymbolName: layoutMode == .grid ? "list.bullet" : "square.grid.2x2",
      accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
    layoutToggle?.toolTip = layoutMode == .grid ? L("以列表显示") : L("以网格显示")
    tagButton?.image = NSImage(
      systemSymbolName: query.tag == nil ? "tag" : "tag.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
    tagButton?.toolTip = query.tag.map { L("标签：\($0)") } ?? L("按标签筛选")
  }

  /// 空状态文案：区分「还没有主机」「目录读失败」与「没有匹配」。
  func emptyStateText() -> String? {
    guard listing.groups.isEmpty, listing.hosts.isEmpty else { return nil }
    if let error = directory.loadError { return L("无法读取主机列表：\(error)") }
    if directory.savedHosts.isEmpty {
      return L("还没有保存的主机。点「新建主机」添加，或从 ~/.ssh/config 导入；也可以直接在上方输入 user@host 连接。")
    }
    // 输入的是可连接地址时，告诉用户回车就能临时连接，而不是只说「没有匹配」。
    if case .target(let target)? = HostBrowserCatalog.connectIntent(
      query: query.search, hosts: directory.hosts, visible: listing.hosts)
    {
      return L("没有匹配的主机。按回车或点「连接」直接连接 \(target.displayText)。")
    }
    return L("没有匹配的主机。")
  }

  /// 卡片副标题里用的缺省用户名。
  var defaultUser: String {
    let defaults = directory.hosts.first(where: \.isDefaults)?.user ?? ""
    return defaults.isEmpty ? localUser : defaults
  }

  /// 卡片区可见的分区与空状态。
  func applySectionVisibility(hasGroups: Bool, hasHosts: Bool) {
    groupsTitle.isHidden = !hasGroups
    groupsGrid.isHidden = !hasGroups
    hostsTitle.isHidden = !hasHosts
    hostsGrid.isHidden = !hasHosts
    let empty = emptyStateText()
    emptyLabel.stringValue = empty ?? ""
    emptyLabel.isHidden = empty == nil
  }
}
