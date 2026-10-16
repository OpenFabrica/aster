// 侧栏「主机」页的「已知主机」子页：按文件分组列出 known_hosts 记录，可搜索、重新加载、删除。
// 列出、校验与删除都交给 `SSHKnownHostsService`；这里只负责呈现与确认。
import AppKit
import AsterCore

/// 「已知主机」子页控制器。外壳 `HostsHubViewController` 首次切到该子页时创建，之后复用。
@MainActor
final class KnownHostsPageViewController: NSViewController, HostsHubPage, NSTextFieldDelegate {
  let service: SSHKnownHostsService
  /// 提示的出口；nil 时转给外壳所属窗口的 `AppModel.notice`（工作区 toast）。
  private let notify: ((String, Bool) -> Void)?

  let searchField = NSTextField()
  private(set) var reloadButton: HostsPagePillButton!
  /// 最近一次渲染的分组，供测试读取。
  private(set) var sections: [KnownHostsPageSection] = []
  /// 最近一次渲染的记录行，供测试与截图读取。
  private(set) var rowViews: [KnownHostsEntryRowView] = []

  private let searchBar = HostsPageFilledView(fillColor: HostsPagePalette.control, cornerRadius: 9)
  private let scrollView = NSScrollView()
  private let contentStack = NSStackView()
  private let errorBanner = HostsPageFilledView(fillColor: KnownHostsPagePalette.warningFill, cornerRadius: 8)
  private let errorLabel = makeLabel("", size: 12, color: AsterTheme.ink)
  private let statusLabel = makeLabel("", size: 12.5, color: AsterTheme.secondaryInk)
  private let spinner = NSProgressIndicator()

  /// 生产用 `SSHKnownHostsService.live()`；测试注入假的服务与提示出口。
  init(service: SSHKnownHostsService = .live(), notify: ((String, Bool) -> Void)? = nil) {
    self.service = service
    self.notify = notify
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("known-hosts-page")
    view = root
    buildLayout(in: root)
    service.didChange = { [weak self] in self?.render() }
    service.toast = { [weak self] text, isError in self?.showNotice(text, isError: isError) }
    render()
  }

  /// 子页变为可见：首次显示时自动列出一次，并把键盘焦点交给搜索框。
  ///
  /// 已加载过就不再自动刷新：工作区每次整树重建（例如弹出 toast）都会回调这里，
  /// 自动刷新会让删除后的提示又触发一次读取；需要最新内容时用「重新加载」。
  func pageDidAppear() {
    // 主题可能在页面隐藏期间换过：底色视图按新外观重画。
    searchBar.needsDisplay = true
    errorBanner.needsDisplay = true
    if service.state == .idle { service.refresh() }
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.view.window, window.firstResponder !== self.searchField.currentEditor()
      else { return }
      window.makeFirstResponder(self.searchField)
    }
  }

  // MARK: - 布局

  /// 搜索条（含重新加载）、说明、错误横幅与可滚动的分组列表。
  private func buildLayout(in root: NSView) {
    let bar = makeSearchBar()
    let hint = makeLabel(
      L("连接时校验主机密钥用的记录。删除后，下次连接会重新询问是否信任这台主机。"),
      size: 12, color: AsterTheme.secondaryInk)
    hint.lineBreakMode = .byWordWrapping
    hint.maximumNumberOfLines = 0
    hint.identifier = NSUserInterfaceItemIdentifier("known-hosts-hint")
    configureErrorBanner()
    configureScrollView()
    // 顶部用栈排列：错误横幅隐藏时栈会把它摘掉，不留空白。
    let header = NSStackView(views: [bar, hint, errorBanner])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 12
    header.detachesHiddenViews = true
    for view in [bar, errorBanner] as [NSView] {
      view.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
    }
    hint.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -4).isActive = true
    for subview in [header, scrollView] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(subview)
    }
    let inset: CGFloat = 24
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  /// 与「主机」子页同款的宽搜索条：放大镜 + 输入框 + 右端「重新加载」。
  private func makeSearchBar() -> NSView {
    let bar = searchBar
    bar.identifier = NSUserInterfaceItemIdentifier("known-hosts-search-bar")
    bar.heightAnchor.constraint(equalToConstant: InterfaceScale.length(40)).isActive = true
    let glass = NSImageView()
    glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(13), weight: .medium))
    glass.contentTintColor = AsterTheme.tertiaryInk
    glass.translatesAutoresizingMaskIntoConstraints = false

    searchField.identifier = NSUserInterfaceItemIdentifier("known-hosts-search-field")
    searchField.placeholderString = L("按主机、指纹或算法搜索")
    searchField.isBordered = false
    searchField.drawsBackground = false
    searchField.focusRingType = .none
    searchField.font = NSFont.interface(ofSize: 14)
    searchField.textColor = AsterTheme.ink
    searchField.delegate = self
    searchField.cell?.isScrollable = true
    searchField.cell?.wraps = false
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.setAccessibilityLabel(L("搜索已知主机"))

    reloadButton = HostsPagePillButton(title: L("重新加载"), symbol: "arrow.clockwise") { [weak self] in
      self?.service.refresh()
    }
    reloadButton.identifier = NSUserInterfaceItemIdentifier("known-hosts-reload")
    for subview in [glass, searchField, reloadButton!] as [NSView] { bar.addSubview(subview) }
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 13),
      glass.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 9),
      searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      searchField.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -10),
      reloadButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -5),
      reloadButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
    ])
    return bar
  }

  /// 读取失败横幅：保留上一次列表的同时说明这次为什么没读到。
  private func configureErrorBanner() {
    errorBanner.identifier = NSUserInterfaceItemIdentifier("known-hosts-error")
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
    icon.contentTintColor = AsterTheme.warning
    // 图标视图默认贴合优先级低，会被拉宽把文字挤到右侧；固定为内容宽度。
    icon.setContentHuggingPriority(.required, for: .horizontal)
    errorLabel.lineBreakMode = .byWordWrapping
    errorLabel.maximumNumberOfLines = 0
    errorLabel.isSelectable = true
    for subview in [icon, errorLabel] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      errorBanner.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: errorBanner.leadingAnchor, constant: 12),
      icon.topAnchor.constraint(equalTo: errorBanner.topAnchor, constant: 9),
      errorLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      errorLabel.trailingAnchor.constraint(equalTo: errorBanner.trailingAnchor, constant: -12),
      errorLabel.topAnchor.constraint(equalTo: errorBanner.topAnchor, constant: 8),
      errorLabel.bottomAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: -8),
    ])
  }

  /// 透明滚动视图 + 竖排的状态行与文件分组。
  private func configureScrollView() {
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = document

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    statusLabel.identifier = NSUserInterfaceItemIdentifier("known-hosts-status")
    statusLabel.lineBreakMode = .byWordWrapping
    statusLabel.maximumNumberOfLines = 0
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 22
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(contentStack)
    let clip = scrollView.contentView
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
      contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
      contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
      contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
    ])
  }

  // MARK: - 搜索框

  /// 输入即过滤。
  func controlTextDidChange(_ obj: Notification) {
    render()
  }

  /// Esc 清空搜索词。
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)), !searchField.stringValue.isEmpty else {
      return false
    }
    searchField.stringValue = ""
    render()
    return true
  }

  // MARK: - 渲染

  /// 按服务状态与搜索词重建列表、重新加载按钮与错误横幅。
  func render() {
    guard isViewLoaded else { return }
    let loading = service.state == .loading || service.state == .idle
    reloadButton.title = loading ? L("正在读取…") : L("重新加载")
    reloadButton.isEnabled = !loading
    reloadButton.alphaValue = loading ? 0.55 : 1
    reloadButton.invalidateIntrinsicContentSize()

    if case .failed(let message) = service.state {
      errorLabel.stringValue = message
      errorBanner.isHidden = false
    } else {
      errorBanner.isHidden = true
    }

    if let listing = service.listing {
      sections = KnownHostsPageContent.sections(
        listing: listing, query: searchField.stringValue,
        names: service.names(for:), isRemovable: service.isRemovable)
    } else {
      sections = []
    }
    var views: [NSView] = []
    if let status = statusText(loading: loading) {
      views.append(makeStatusRow(status, showsSpinner: loading && service.listing == nil))
    }
    rowViews = []
    views += sections.map(makeSectionView)
    contentStack.setViews(views, in: .top)
    for view in views {
      view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }
  }

  /// 列表上方的状态文字：首次读取中、没有可列出的文件；有列表时不显示。
  private func statusText(loading: Bool) -> String? {
    guard let listing = service.listing else { return loading ? L("正在读取…") : nil }
    return listing.files.isEmpty ? L("没有可列出的 known_hosts 文件。") : nil
  }

  /// 状态行：可选的转圈 + 文字。
  private func makeStatusRow(_ text: String, showsSpinner: Bool) -> NSView {
    statusLabel.stringValue = text
    if showsSpinner { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    let row = NSStackView(views: showsSpinner ? [spinner, statusLabel] : [statusLabel])
    row.orientation = .horizontal
    row.spacing = 8
    return row
  }

  /// 一个文件分组：标题（路径、记录数、徽章）+ 记录卡片。
  private func makeSectionView(_ section: KnownHostsPageSection) -> NSView {
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(12), weight: .medium))
    icon.contentTintColor = AsterTheme.secondaryInk
    let path = makeLabel(section.displayPath, size: 13, weight: .semibold, color: AsterTheme.ink)
    path.toolTip = section.file.path
    path.isSelectable = true
    path.lineBreakMode = .byTruncatingMiddle
    path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let count = makeLabel("· \(section.total)", size: 12.5, color: AsterTheme.tertiaryInk)
    let badges = KnownHostsPageContent.badges(for: section.file).map {
      makeKnownHostsBadge($0, identifier: "known-hosts-file-badge")
    }
    let header = NSStackView(views: [icon, path, count] + badges)
    header.orientation = .horizontal
    header.spacing = 6
    header.setCustomSpacing(10, after: count)
    header.identifier = NSUserInterfaceItemIdentifier("known-hosts-file-\(section.file.path)")

    let container = NSStackView(views: [header] + [makeCard(section)].compactMap { $0 })
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = 8
    for view in container.arrangedSubviews.dropFirst() {
      view.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }
    return container
  }

  /// 记录卡片：各行之间细分隔线，末尾是占位说明与跳过行提示；什么都没有时不画卡片。
  private func makeCard(_ section: KnownHostsPageSection) -> NSView? {
    var items: [NSView] = section.rows.map { row in
      let view = KnownHostsEntryRowView(row: row, deleteEnabled: !service.isRemoving) { [weak self] in
        self?.confirmRemove(row)
      }
      rowViews.append(view)
      return view
    }
    if let placeholder = section.placeholder { items.append(makeNoteRow(placeholder, identifier: "known-hosts-empty")) }
    if !section.skippedLines.isEmpty {
      let lines = section.skippedLines.map(String.init).joined(separator: "、")
      items.append(
        makeNoteRow(
          L("\(String(section.skippedLines.count)) 行无法解析，已跳过（第 \(lines) 行）"),
          identifier: "known-hosts-skipped"))
    }
    guard !items.isEmpty else { return nil }
    let card = HostsPageFilledView(fillColor: HostsPagePalette.card, cornerRadius: 10)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    for (index, item) in items.enumerated() {
      if index > 0 {
        let line = HostsPageFilledView(fillColor: AsterTheme.divider, cornerRadius: 0)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(line)
        // 记录之间的分隔线从文字列开始（让出图标块），说明行之间从卡片内边距开始。
        let betweenRows = item is KnownHostsEntryRowView && items[index - 1] is KnownHostsEntryRowView
        line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: betweenRows ? 54 : 14).isActive = true
        line.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
      }
      stack.addArrangedSubview(item)
      item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    card.addSubview(stack)
    stack.pinEdges(to: card)
    return card
  }

  /// 卡片里的一行说明文字（空状态、跳过的行）。
  private func makeNoteRow(_ text: String, identifier: String) -> NSView {
    let container = NSView()
    container.identifier = NSUserInterfaceItemIdentifier(identifier)
    let label = makeLabel(text, size: 12, color: AsterTheme.secondaryInk)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
      label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),
    ])
    return container
  }

  // MARK: - 删除

  /// 删除入口：在窗口上弹出确认 sheet；没有窗口（测试）时不弹。返回弹出的确认框。
  @discardableResult
  func confirmRemove(_ row: KnownHostsPageRow) -> NSAlert? {
    guard row.removable, !service.isRemoving, let window = view.window else { return nil }
    let (alert, choices) = makeDeleteAlert(for: row)
    alert.beginSheetModal(for: window) { [weak self] response in
      let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      guard choices.indices.contains(index), let choice = choices[index] else { return }
      self?.remove(row.entry, choice: choice)
    }
    return alert
  }

  /// 构造删除确认框与按钮对应的选项（最后一项 nil 是「取消」）。
  /// 多主机行可以只删其中一台；单主机行只有「删除」。
  func makeDeleteAlert(for row: KnownHostsPageRow) -> (NSAlert, [KnownHostsDeleteChoice?]) {
    let entry = row.entry
    let choices = KnownHostsPageContent.deleteChoices(for: entry)
    let multiple = entry.hosts.count > 1
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("删除这条 known_hosts 记录？")
    var info = [
      multiple
        ? L("这一行同时覆盖多台主机。删除整行后，它们下次连接都要重新确认主机密钥。")
        : L("删除后，下次连接这台主机时会重新询问是否信任它的密钥。")
    ]
    if !row.covered.isEmpty { info.append(row.covered.map { "• \($0)" }.joined(separator: "\n")) }
    info.append(
      "\(SSHKnownHostsService.displayPath(entry.file)) · " + L("第 \(String(entry.line)) 行")
        + "\n\(entry.algorithm) \(entry.fingerprint)")
    alert.informativeText = info.joined(separator: "\n\n")
    for choice in choices {
      switch choice {
      case .line:
        let button = alert.addButton(withTitle: multiple ? L("删除整行") : L("删除"))
        button.hasDestructiveAction = true
      case .host(let endpoint):
        alert.addButton(withTitle: L("只删除 \(KnownHostsPageContent.endpointText(endpoint))"))
      }
    }
    alert.addButton(withTitle: L("取消")).keyEquivalent = "\u{1b}"
    return (alert, choices.map(Optional.some) + [nil])
  }

  /// 按确认的选项提交删除；结果提示与重新列出由服务负责。
  func remove(_ entry: SSHKnownHostsListing.Entry, choice: KnownHostsDeleteChoice) {
    let host: SSHHostPort? =
      switch choice {
      case .line: nil
      case .host(let endpoint): endpoint
      }
    service.remove(
      SSHKnownHostsRemoveRequest(file: entry.file, line: entry.line, lineDigest: entry.lineDigest, host: host))
  }

  /// 显示一条提示：优先用注入的出口，否则交给外壳所属窗口的工作区 toast。
  private func showNotice(_ text: String, isError: Bool) {
    if let notify {
      notify(text, isError)
    } else {
      (parent as? HostsHubViewController)?.model.notice = text
    }
  }
}
