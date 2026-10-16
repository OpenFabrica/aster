// 侧栏「主机」页的「密钥」子页（私钥保险库）：搜索框、导入 / 生成工具栏、提示横幅、密钥卡片网格
// 与右侧详情面板。动作全部交给 `SSHVaultKeyActions`，这里只负责展示、确认与选择状态。
import AppKit
import AsterCore
import Combine

/// 「密钥」子页控制器。外壳缓存同一实例，搜索词与选中的密钥在切换子页后保留。
///
/// 密钥数据只从 `SSHVaultKeyDirectory` 读（经 `SSHVaultKeyActions.rows`），主机名从 `SSHHostDirectory` 读；
/// 两者发布变化时重算卡片，这里不持有可写副本。
@MainActor
final class HostsKeysViewController: NSViewController, NSTextFieldDelegate, HostsHubPage {
  let actions: SSHVaultKeyActions
  let prompts: HostsKeysPrompts
  /// 提示的去处；nil 时写到所在窗口的 `AppModel.notice`（工作区底部的 toast）。
  private let notifyOverride: ((String, Bool) -> Void)?

  private(set) var query = ""
  /// 当前全部展示行（按名称排序）与过滤后的可见行。
  private(set) var rows: [SSHVaultKeyRow] = []
  private(set) var visibleRows: [SSHVaultKeyRow] = []
  /// 详情面板显示的密钥；nil 表示面板收起。
  private(set) var selectedID: UUID?
  /// 最近一条错误提示；生成 / 重命名失败后重新弹表单时显示原因。
  var lastError: String?

  let searchField = NSTextField()
  private(set) var importButton: HostsPagePillButton!
  private(set) var generateButton: HostsPagePillButton!
  let grid = HostsPageGridView(rowHeight: InterfaceScale.length(HostsKeyCardView.height))
  private(set) lazy var detailView = HostsKeyDetailView(handlers: makeDetailHandlers())
  private let searchBar = HostsPageFilledView(fillColor: HostsPagePalette.control, cornerRadius: 9)
  private let bannerStack = NSStackView()
  private let sectionTitle = makeHostsPageSectionTitle(L("密钥"), identifier: "hosts-keys-section-title")
  private let emptyLabel = makeLabel("", size: 12.5, color: AsterTheme.secondaryInk)
  private let scrollView = NSScrollView()
  private var listTrailingToDetail: NSLayoutConstraint!
  private var listTrailingToRoot: NSLayoutConstraint!
  private var cancellables: Set<AnyCancellable> = []

  /// 生产用共享保险库与主机目录、原生对话框；测试注入临时目录、假工具与假对话框。
  init(
    actions: SSHVaultKeyActions = SSHVaultKeyActions(dependencies: .live(), hosts: .shared),
    prompts: HostsKeysPrompts = .live,
    notify: ((String, Bool) -> Void)? = nil
  ) {
    self.actions = actions
    self.prompts = prompts
    notifyOverride = notify
    super.init(nibName: nil, bundle: nil)
    actions.toast = { [weak self] text, isError in self?.notify(text, isError: isError) }
    actions.window = { [weak self] in self?.view.window }
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("hosts-keys-page")
    view = root
    buildLayout(in: root)
    // @Published 在 willSet 时发出，此刻值还是旧的；切到下一轮主队列再读。
    let directory = actions.directory
    Publishers.MergeMany(
      directory.$keys.map { _ in () }.eraseToAnyPublisher(),
      directory.$loadError.map { _ in () }.eraseToAnyPublisher(),
      directory.$keychainMissing.map { _ in () }.eraseToAnyPublisher(),
      actions.hosts.$hosts.map { _ in () }.eraseToAnyPublisher(),
      actions.$isBusy.map { _ in () }.eraseToAnyPublisher()
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.reload() }
    .store(in: &cancellables)
    reload()
  }

  /// 子页可见时：后台刷新钥匙串缺失标记、按新主题重画，并把键盘焦点交给搜索框。
  func pageDidAppear() {
    actions.directory.refreshKeychainPresence()
    searchBar.needsDisplay = true
    detailView.refreshAppearance()
    reload()
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.view.window else { return }
      window.makeFirstResponder(self.searchField)
    }
  }

  // MARK: - 提示

  /// 显示一条提示；错误同时记进 `lastError`，供重新弹出的表单说明原因。
  func notify(_ text: String, isError: Bool) {
    if isError { lastError = text }
    if let notifyOverride {
      notifyOverride(text, isError)
    } else {
      (parent as? HostsHubViewController)?.model.notice = text
    }
  }

  // MARK: - 布局

  /// 搜索框、工具栏、横幅在上；下方左边卡片区，右边详情面板。
  private func buildLayout(in root: NSView) {
    let header = NSStackView(views: [makeSearchBar(), makeToolbar(), bannerStack])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 14
    header.setCustomSpacing(10, after: header.arrangedSubviews[1])
    bannerStack.orientation = .vertical
    bannerStack.alignment = .leading
    bannerStack.spacing = 8
    configureScrollView()
    detailView.isHidden = true
    for subview in [header, scrollView, detailView] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(subview)
    }
    for child in header.arrangedSubviews {
      child.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
    }
    let inset: CGFloat = 24
    listTrailingToRoot = scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
    listTrailingToDetail = scrollView.trailingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 2)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      listTrailingToRoot,

      detailView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 14),
      detailView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
      detailView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
      detailView.widthAnchor.constraint(equalToConstant: InterfaceScale.length(HostsKeyDetailView.width)),
    ])
  }

  /// 顶部宽搜索框：放大镜 + 输入框，与「主机」子页同一样式。
  private func makeSearchBar() -> NSView {
    let bar = searchBar
    bar.identifier = NSUserInterfaceItemIdentifier("hosts-keys-search-bar")
    bar.heightAnchor.constraint(equalToConstant: InterfaceScale.length(40)).isActive = true
    let glass = NSImageView()
    glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(13), weight: .medium))
    glass.contentTintColor = AsterTheme.tertiaryInk
    searchField.identifier = NSUserInterfaceItemIdentifier("hosts-keys-search-field")
    searchField.placeholderString = L("查找密钥（名称、指纹、主机）…")
    searchField.setAccessibilityLabel(L("查找密钥（名称、指纹、主机）…"))
    searchField.isBordered = false
    searchField.drawsBackground = false
    searchField.focusRingType = .none
    searchField.font = NSFont.interface(ofSize: 14)
    searchField.textColor = AsterTheme.ink
    searchField.delegate = self
    searchField.cell?.isScrollable = true
    searchField.cell?.wraps = false
    for subview in [glass, searchField] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      bar.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 13),
      glass.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 9),
      searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      searchField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -13),
    ])
    return bar
  }

  /// 工具栏：导入、生成；右侧说明私钥不能导出。
  private func makeToolbar() -> NSView {
    importButton = HostsPagePillButton(title: L("导入私钥…"), symbol: "square.and.arrow.down") {
      [weak self] in self?.importKey()
    }
    importButton.identifier = NSUserInterfaceItemIdentifier("hosts-keys-import")
    importButton.toolTip = L("从 ~/.ssh 等位置选择私钥文件导入钥匙串")
    generateButton = HostsPagePillButton(title: L("生成新密钥…"), symbol: "plus") { [weak self] in
      self?.generateKey()
    }
    generateButton.identifier = NSUserInterfaceItemIdentifier("hosts-keys-generate")
    let note = makeLabel(L("私钥只保存在钥匙串里，不能导出。"), size: 11.5, color: AsterTheme.tertiaryInk)
    note.identifier = NSUserInterfaceItemIdentifier("hosts-keys-note")
    note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [generateButton, importButton, spacer, note])
    row.orientation = .horizontal
    row.spacing = 10
    return row
  }

  /// 卡片区：透明滚动视图 + 分区标题、卡片网格与空状态。
  private func configureScrollView() {
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = document
    emptyLabel.identifier = NSUserInterfaceItemIdentifier("hosts-keys-empty")
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.maximumNumberOfLines = 0
    let stack = NSStackView(views: [sectionTitle, grid, emptyLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
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
      grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
      emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  /// 一条提示横幅：警示图标 + 可换行文字。
  private func makeBanner(_ text: String, identifier: String) -> NSView {
    let banner = HostsPageFilledView(fillColor: NSColor.systemOrange.withAlphaComponent(0.14), cornerRadius: 8)
    banner.identifier = NSUserInterfaceItemIdentifier(identifier)
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
    icon.contentTintColor = .systemOrange
    // NSImageView 默认横向拥抱优先级低，会被拉宽把图标居中到横幅中间；固定为图标本身的宽度。
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)
    let label = makeLabel(text, size: 12, color: AsterTheme.ink)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for subview in [icon, label] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      banner.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
      icon.topAnchor.constraint(equalTo: label.topAnchor, constant: 1),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
      label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 9),
      label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -9),
    ])
    return banner
  }

  // MARK: - 搜索框

  /// 输入即过滤。
  func controlTextDidChange(_ obj: Notification) {
    query = searchField.stringValue
    reload()
  }

  /// Esc 先清空搜索词，再收起详情面板。
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    if !searchField.stringValue.isEmpty {
      searchField.stringValue = ""
      query = ""
      reload()
    } else if selectedID != nil {
      select(nil)
    }
    return true
  }

  // MARK: - 状态

  /// 选中一把密钥并打开详情面板；nil 收起面板。
  func select(_ id: UUID?) {
    selectedID = id
    reload()
  }

  /// 按当前目录、搜索词与选择重算卡片、横幅、详情面板与按钮状态。
  func reload() {
    guard isViewLoaded else { return }
    rows = actions.rows(hosts: actions.hosts.hosts)
    visibleRows = rows.filter { $0.matches(query) }
    // 选中的密钥被删掉（含外部修改 ssh-keys.json）后收起面板。
    if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    grid.setItems(visibleRows.map(makeCard))
    // 没有任何密钥时只显示空状态说明，不留一个孤零零的分区标题。
    sectionTitle.isHidden = rows.isEmpty
    sectionTitle.stringValue = L("密钥（\(String(rows.count))）")
    let empty = emptyStateText()
    emptyLabel.stringValue = empty ?? ""
    emptyLabel.isHidden = empty == nil
    grid.isHidden = visibleRows.isEmpty
    updateBanners()
    updateDetail()
    for button in [importButton, generateButton] as [HostsPagePillButton] {
      button.isEnabled = !actions.isBusy
      button.alphaValue = button.isEnabled ? 1 : 0.45
    }
  }

  /// 空状态文案：区分「还没有密钥」与「没有匹配」。
  func emptyStateText() -> String? {
    guard visibleRows.isEmpty else { return nil }
    if rows.isEmpty {
      return L("还没有保险库密钥。导入 ~/.ssh 里的私钥，或生成一把新的 Ed25519 密钥。")
    }
    return L("没有匹配的密钥。")
  }

  /// openssh 引擎与目录读取失败的横幅。
  private func updateBanners() {
    var banners: [NSView] = []
    if actions.dependencies.engine() == .openssh {
      banners.append(makeBanner(
        L("保险库密钥只在原生 SSH 引擎下生效；当前使用 OpenSSH 回退引擎，连接时不会用到这些密钥。"),
        identifier: "hosts-keys-engine-banner"))
    }
    if let error = actions.directory.loadError {
      banners.append(makeBanner(
        L("ssh-keys.json 无法读取，正在显示最后一次有效内容：\(error)"), identifier: "hosts-keys-error-banner"))
    }
    bannerStack.setViews(banners, in: .top)
    for banner in banners { banner.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true }
    bannerStack.isHidden = banners.isEmpty
  }

  /// 有选中的密钥时显示详情面板并让卡片区让出宽度。
  private func updateDetail() {
    let row = selectedID.flatMap { id in rows.first { $0.id == id } }
    if let row { detailView.show(row, isBusy: actions.isBusy) }
    let visible = row != nil
    guard detailView.isHidden == visible else { return }
    detailView.isHidden = !visible
    listTrailingToRoot.isActive = !visible
    listTrailingToDetail.isActive = visible
  }

  /// 一张密钥卡片：单击选中，右键菜单。
  private func makeCard(_ row: SSHVaultKeyRow) -> HostsKeyCardView {
    let id = row.id
    return HostsKeyCardView(
      row: row, isSelected: id == selectedID,
      onSelect: { [weak self] in self?.select(self?.selectedID == id ? nil : id) },
      menuProvider: { [weak self] in self?.makeKeyMenu(id) ?? NSMenu() })
  }
}
