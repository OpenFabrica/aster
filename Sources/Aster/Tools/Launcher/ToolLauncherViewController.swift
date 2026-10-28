// 工具面板的内容：大搜索框 → 结果列表（「识别到」+ 搜索结果，⌘1–9 快选）→ 选中工具后在下方展开的
// 工具界面 → 底部按键提示。键盘按 ToolLauncherKeyRouter 路由；打开、预填、开成 Pane 等意图交给
// delegate（窗口控制器）执行，这里只负责展示与输入。
import AppKit
import AsterCore

/// 工具面板的内容控制器。
@MainActor
final class ToolLauncherViewController: NSViewController, NSTextFieldDelegate {
  static let searchRowHeight: CGFloat = 56
  static let footerHeight: CGFloat = 30
  static let maximumVisibleRows = 8
  /// 一次最多列出的结果；「识别到」另算。
  private static let searchLimit = 40
  private static let recognizedLimit = 5
  /// 拖入文件的上限，与 match 规则 `maxCount` 的上限一致。
  private static let maximumDroppedFiles = 100

  weak var delegate: ToolLauncherContentDelegate?
  /// 内容区最多能用的高度（屏幕可见高度减去边距），由窗口控制器在呼出时设置。
  var maximumContentHeight: CGFloat = 800

  private let searchBar = ToolLauncherSearchBar(height: ToolLauncherViewController.searchRowHeight)
  private var searchField: NSTextField { searchBar.searchField }
  private var toolChip: NSTextField { searchBar.toolChip }
  private var filesButton: NSButton { searchBar.filesButton }
  private var pinButton: NSButton { searchBar.pinButton }
  private let resultsStack = NSStackView()
  private let resultsScroll = NSScrollView()
  private let emptyLabel = makeLabel("", size: 12, color: AsterTheme.secondaryInk)
  private let toolContainer = NSView()
  private let footer = ToolLauncherFooterView()
  private var resultsHeightConstraint: NSLayoutConstraint?
  private var toolHeightConstraint: NSLayoutConstraint?
  private var rowPool: [ToolLauncherRowView] = []
  private var rowViews: [ToolLauncherRowView] = []
  private var keyMonitor: Any?
  private var showsCommandHints = false
  private var context = ToolContext()
  private var contentInput: ToolInput?
  private var toolHeight: CGFloat = 360

  private(set) var rows: [ToolLauncherRow] = []
  private(set) var selectedIndex = 0
  /// 拖入面板的文件（绝对路径）。
  private(set) var files: [String] = []
  /// 结果列表下方正展开着工具。
  private(set) var isToolOpen = false

  /// 钉住按钮的显示状态；真值在窗口控制器。
  var isPinned: Bool {
    get { searchBar.isPinned }
    set { searchBar.isPinned = newValue }
  }

  /// 当前选中的结果行。
  var selectedRow: ToolLauncherRow? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

  /// 打开某一行时交给工具的输入。
  func launchInput(for row: ToolLauncherRow) -> ToolInput {
    ToolLauncherResults.launchInput(for: row, contentInput: contentInput, files: files, context: context)
  }

  /// 兜底移除键盘监视。
  /// 搜索框专用的 field editor：拖到搜索框上的文件按文件输入处理，不把路径插成文字。
  private lazy var searchFieldEditor: ToolLauncherSearchFieldEditor = {
    let editor = ToolLauncherSearchFieldEditor()
    editor.isFieldEditor = true
    editor.onDropFiles = { [weak self] paths in self?.receiveDroppedFiles(paths) }
    return editor
  }()

  /// 面板向窗口要 field editor 时调用：搜索框用专用的那个，其它控件返回 nil（用系统默认）。
  func fieldEditor(for client: Any?) -> NSText? {
    (client as AnyObject?) === searchField ? searchFieldEditor : nil
  }

  isolated deinit {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
  }

  // MARK: - 视图

  /// 搭建内容：自上而下 搜索行、分隔线、结果区 / 工具区、分隔线、底部提示。整列贴顶，窗口高度
  /// 由控制器按 `preferredContentHeight` 设置，动画过程中多出来的部分只露出背景。
  override func loadView() {
    let root = ToolLauncherRootView()
    root.onDropFiles = { [weak self] paths in self?.receiveDroppedFiles(paths) }

    let column = NSStackView(views: [
      makeSearchRow(), makeSeparator(), makeResultsArea(), makeToolArea(), makeSeparator(), makeFooter(),
    ])
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 0
    column.translatesAutoresizingMaskIntoConstraints = false
    // `.width` 对齐挡不住没有固有宽度的滚动视图被行内容的自然宽度压窄、贴到右边；
    // 与 Open Quickly 一样给每个子视图显式加等宽约束。
    for arranged in column.arrangedSubviews {
      arranged.translatesAutoresizingMaskIntoConstraints = false
      arranged.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: root.topAnchor),
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
    ])
    view = root
    toolContainer.isHidden = true
    reloadResults()
  }

  /// 搜索行（见 ToolLauncherSearchBar）：这里接上搜索框的 delegate 与文件标记的点击动作。
  private func makeSearchRow() -> NSView {
    searchField.placeholderString = Self.searchPlaceholder
    searchField.delegate = self
    filesButton.target = self
    filesButton.action = #selector(clearDroppedFiles)
    pinButton.target = self
    pinButton.action = #selector(togglePin)
    return searchBar
  }

  /// 结果区：滚动视图里的一列结果行，高度随行数变化。
  private func makeResultsArea() -> NSView {
    resultsStack.orientation = .vertical
    resultsStack.alignment = .width
    resultsStack.spacing = 2
    // 行宽约束成等于栈宽（`attach(to:)`），栈的左右内边距会被压掉；左右留白改由栈相对文档视图缩进 8pt。
    resultsStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    let document = FlippedDocumentView()
    document.addSubview(resultsStack)
    resultsStack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    resultsScroll.drawsBackground = false
    resultsScroll.hasVerticalScroller = true
    resultsScroll.autohidesScrollers = true
    resultsScroll.documentView = document
    let height = resultsScroll.heightAnchor.constraint(equalToConstant: 1)
    resultsHeightConstraint = height
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: resultsScroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: resultsScroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor),
      resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
      resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
      resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(equalTo: resultsStack.bottomAnchor),
      height,
    ])
    return resultsScroll
  }

  /// 工具区：容纳工具界面，高度跟随工具的请求。
  private func makeToolArea() -> NSView {
    let height = toolContainer.heightAnchor.constraint(equalToConstant: toolHeight)
    toolHeightConstraint = height
    height.isActive = true
    return toolContainer
  }

  /// 一像素分隔线。
  private func makeSeparator() -> NSView {
    let line = ToolLauncherSeparatorView()
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }

  /// 底栏：按键提示与短提示。
  private func makeFooter() -> NSView {
    footer.heightAnchor.constraint(equalToConstant: Self.footerHeight).isActive = true
    updateHints()
    return footer
  }

  private static var searchPlaceholder: String { L("搜索工具，或粘贴要处理的内容…") }

  // MARK: - 呼出与收起

  /// 每次呼出前重置：清空查询与拖入的文件，回到结果列表。`context` 是这次来源 Pane 的环境。
  func reset(context: ToolContext) {
    loadViewIfNeeded()
    self.context = context
    files = []
    searchField.stringValue = ""
    detachToolView()
    footer.hideNotice()
    selectedIndex = 0
    reloadResults()
  }

  /// 来源 Pane 变了（钉住的面板重新拿到键盘时）：换上新环境，按搜索框里现有的文字重新匹配。
  func updateContext(_ context: ToolContext) {
    loadViewIfNeeded()
    self.context = context
    guard !isToolOpen else { return }
    reloadResults()
  }

  /// 鼠标按在这里时拖动面板：搜索行里搜索框与按钮以外的空白（放大镜、四周留白、工具名），以及整条底栏。
  /// 结果行、工具界面与输入控件照常接收点击。
  func isDragHandle(_ hit: NSView) -> Bool {
    if hit.isDescendant(of: footer) { return true }
    guard hit.isDescendant(of: searchBar) else { return false }
    return !hit.isDescendant(of: searchField) && !(hit is NSButton)
  }

  /// 面板显示后：把输入交给搜索框，并在面板是 key 的期间拦截面板快捷键。
  func didPresent() {
    focusSearchField()
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
  }

  /// 面板收起后移除监视，免得拦截工作区窗口里的按键。
  func didDismiss() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    setCommandHintsVisible(false)
  }

  /// 搜索框成为 first responder，光标放到末尾。
  func focusSearchField() {
    guard let window = view.window else { return }
    window.makeFirstResponder(searchField)
    searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.utf16.count, length: 0)
  }

  /// 面板需要的内容高度。
  var preferredContentHeight: CGFloat {
    Self.searchRowHeight + 2 + Self.footerHeight + (isToolOpen ? clampedToolHeight : resultsHeight)
  }

  // MARK: - 工具区

  /// 在结果列表的位置展开工具界面；搜索框留下 `queryText`，之后的输入交给工具。
  func presentTool(_ session: ToolSessionViewController, title: String, queryText: String) {
    detachToolView()
    addChild(session)
    toolContainer.addSubview(session.view)
    session.view.pinEdges(to: toolContainer)
    isToolOpen = true
    toolChip.stringValue = title
    toolChip.isHidden = false
    searchField.stringValue = queryText
    searchField.placeholderString = L("继续输入，交给工具处理…")
    resultsScroll.isHidden = true
    toolContainer.isHidden = false
    setToolHeight(session.preferredHeight, notify: false)
    setCommandHintsVisible(false)
    updateHints()
    focusSearchField()
  }

  /// 工具已经由控制器 `teardown()`，这里摘掉视图并回到结果列表，按搜索框里现有的文字重新搜索。
  func dismissTool() {
    detachToolView()
    selectedIndex = 0
    reloadResults()
    focusSearchField()
  }

  /// 工具请求新的内容高度；限制在清单允许的范围与屏幕可用高度内。
  func setToolHeight(_ height: CGFloat, notify: Bool = true) {
    let range = ToolUIConfig.heightRange
    toolHeight = min(max(height.isFinite ? height : 360, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
    toolHeightConstraint?.constant = clampedToolHeight
    if notify { delegate?.launcherContentDidChangeHeight(self, animated: true) }
  }

  /// 屏幕放不下时压缩工具区，搜索框与底部提示永远留着。
  private var clampedToolHeight: CGFloat {
    max(120, min(toolHeight, maximumContentHeight - Self.searchRowHeight - Self.footerHeight - 2))
  }

  /// 摘掉工具视图并恢复结果列表的外观；工具本身由控制器 teardown。
  private func detachToolView() {
    for child in children {
      child.view.removeFromSuperview()
      child.removeFromParent()
    }
    guard isToolOpen else { return }
    isToolOpen = false
    toolChip.isHidden = true
    searchField.placeholderString = Self.searchPlaceholder
    toolContainer.isHidden = true
    resultsScroll.isHidden = false
    updateHints()
  }

  // MARK: - 结果

  /// 按搜索框文字与拖入的文件重新取结果。「识别到」与搜索都由工具中心计算，这里只组装与展示。
  private func reloadResults() {
    let center = ToolCenter.shared
    let input = ToolLauncherResults.contentInput(query: searchField.stringValue, files: files, context: context)
    contentInput = input
    let recognized = input.map { center.contentMatches(for: $0, limit: Self.recognizedLimit) } ?? []
    rows = ToolLauncherResults.rows(
      recognized: recognized, searched: center.search(searchField.stringValue, limit: Self.searchLimit)
    ) { match in
      input.flatMap { center.inlineResult(for: match.entry, input: $0) }
    }
    selectedIndex = rows.isEmpty ? 0 : min(selectedIndex, rows.count - 1)
    renderRows()
  }

  /// 结果区高度：最多露出 8 行，其余滚动；没有结果时留一行放提示。
  private var resultsHeight: CGFloat {
    guard !rows.isEmpty else { return 44 }
    let visible = CGFloat(min(rows.count, Self.maximumVisibleRows))
    return visible * InterfaceScale.length(ToolLauncherRowView.baseHeight) + (visible - 1) * resultsStack.spacing + 12
  }

  /// 复用行视图重画结果。
  private func renderRows() {
    for row in rowViews { row.detachFromResultsStack() }
    for view in resultsStack.arrangedSubviews { view.removeFromSuperview() }
    rowViews.removeAll()
    if rows.isEmpty {
      emptyLabel.stringValue = files.isEmpty ? L("没有匹配的工具") : L("没有能处理这些文件的工具")
      resultsStack.addArrangedSubview(emptyLabel)
    }
    for (index, row) in rows.enumerated() {
      let rowView: ToolLauncherRowView
      if rowPool.indices.contains(index) {
        rowView = rowPool[index]
      } else {
        rowView = ToolLauncherRowView()
        rowPool.append(rowView)
      }
      rowView.configure(row: row) { [weak self] in
        self?.select(index)
        self?.openSelectedRow()
      }
      rowView.onContextMenu = { [weak self] in self?.showContextMenu(forRowAt: index) }
      resultsStack.addArrangedSubview(rowView)
      rowView.attach(to: resultsStack)
      rowViews.append(rowView)
    }
    resultsHeightConstraint?.constant = resultsHeight
    updateSelectionAppearance()
    updateCommandHintAppearance()
    updateHints()
  }

  /// 选中某一行。
  private func select(_ index: Int) {
    guard rows.indices.contains(index) else { return }
    selectedIndex = index
    updateSelectionAppearance()
  }

  /// 上下移动选中项，首尾循环。
  private func moveSelection(_ delta: Int) {
    guard !rows.isEmpty else { return }
    select((selectedIndex + delta + rows.count) % rows.count)
  }

  /// 刷新选中高亮，并把选中行滚到可见。
  private func updateSelectionAppearance() {
    for (index, rowView) in rowViews.enumerated() { rowView.isRowSelected = index == selectedIndex }
    if rowViews.indices.contains(selectedIndex) {
      rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }
    updateHints()
  }

  /// 打开选中行。
  private func openSelectedRow() {
    guard let row = selectedRow else { return }
    // 关键词搜到的工具，搜索框里的字是工具名，打开后清空，后续输入才是给工具的内容；
    // 「识别到」的行把内容留在搜索框里，继续输入就是在改这份内容。
    let queryText = row.origin == .recognized && files.isEmpty ? searchField.stringValue : ""
    delegate?.launcherContent(self, open: row, input: launchInput(for: row), queryText: queryText)
  }

  /// 右键行的操作菜单：打开、复制结果、预填到终端、开成 Pane。
  private func showContextMenu(forRowAt index: Int) {
    guard rowViews.indices.contains(index) else { return }
    select(index)
    let menu = NSMenu()
    menu.addItem(ActionMenuItem(title: L("在工具面板打开")) { [weak self] in self?.openSelectedRow() })
    if let result = rows[index].inlineResult {
      menu.addItem(ActionMenuItem(title: L("复制结果")) { [weak self] in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        self?.showNotice(L("已复制结果"), isError: false)
      })
      menu.addItem(ActionMenuItem(title: L("预填到终端")) { [weak self] in
        guard let self else { return }
        self.delegate?.launcherContentDidRequestPrefill(self)
      })
    }
    menu.addItem(ActionMenuItem(title: L("开成 Pane")) { [weak self] in
      guard let self else { return }
      self.delegate?.launcherContentDidRequestOpenAsPane(self)
    })
    let rowView = rowViews[index]
    menu.popUp(positioning: nil, at: NSPoint(x: rowView.bounds.maxX - 24, y: rowView.bounds.midY), in: rowView)
  }

  // MARK: - 输入

  /// 搜索框文字变化：工具打开时交给工具，否则重新搜索。
  func controlTextDidChange(_ obj: Notification) {
    if isToolOpen {
      delegate?.launcherContent(self, toolQueryChanged: searchField.stringValue)
      return
    }
    selectedIndex = 0
    reloadResults()
    delegate?.launcherContentDidChangeHeight(self, animated: false)
  }

  /// 拖入文件：工具打开时直接交给工具，否则作为「识别到」的匹配内容。
  private func receiveDroppedFiles(_ paths: [String]) {
    let accepted = Array(paths.prefix(Self.maximumDroppedFiles))
    guard !accepted.isEmpty else { return }
    if isToolOpen {
      delegate?.launcherContent(self, toolReceivedFiles: accepted)
      return
    }
    files = accepted
    filesButton.title = L("\(String(accepted.count)) 个文件 ✕")
    filesButton.toolTip = accepted.joined(separator: "\n")
    filesButton.isHidden = false
    selectedIndex = 0
    reloadResults()
    delegate?.launcherContentDidChangeHeight(self, animated: true)
  }

  /// 点图钉切换钉住，然后把键盘还给搜索框。
  @objc private func togglePin() {
    delegate?.launcherContentDidTogglePin(self)
    focusSearchField()
  }

  /// 点文件标记清掉拖入的文件，回到按文字匹配。
  @objc private func clearDroppedFiles() {
    files = []
    filesButton.isHidden = true
    selectedIndex = 0
    reloadResults()
    delegate?.launcherContentDidChangeHeight(self, animated: true)
    focusSearchField()
  }

  /// 面板是 key 期间的按键入口。只处理发往本面板的事件，其余原样放行。
  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let window = view.window, event.window === window else { return event }
    if event.type == .flagsChanged {
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      setCommandHintsVisible(flags.contains(.command) && !isToolOpen)
      return event
    }
    let responder = window.firstResponder
    let editor = searchField.currentEditor()
    let routing = ToolLauncherKeyRouter.Context(
      isToolOpen: isToolOpen,
      isSearchFieldFocused: editor != nil && responder === editor,
      hasMarkedText: (responder as? NSTextView)?.hasMarkedText() == true)
    guard
      let command = ToolLauncherKeyRouter.command(
        keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
        modifiers: event.modifierFlags, context: routing)
    else { return event }
    perform(command)
    return nil
  }

  /// 执行键盘路由出来的面板命令。
  private func perform(_ command: ToolLauncherCommand) {
    switch command {
    case .moveSelection(let delta): moveSelection(delta)
    case .open: openSelectedRow()
    case .quickSelect(let number):
      guard rows.indices.contains(number - 1) else { return }
      select(number - 1)
      openSelectedRow()
    case .prefillResult: delegate?.launcherContentDidRequestPrefill(self)
    case .openAsPane: delegate?.launcherContentDidRequestOpenAsPane(self)
    case .exitTool: delegate?.launcherContentDidRequestExitTool(self)
    case .closePanel: delegate?.launcherContentDidRequestClose(self)
    }
  }

  // MARK: - 提示

  /// 在底部提示栏显示一条短提示；过几秒恢复按键提示。错误用红色。
  func showNotice(_ text: String, isError: Bool) {
    footer.showNotice(text, isError: isError)
  }

  /// 底部按键提示随状态变化：工具打开时 Esc 是「返回」，有行内结果时提示可以预填。
  private func updateHints() {
    var hints: [String] = []
    if isToolOpen {
      hints = [L("⌘↩ 预填到终端"), L("⌥↩ 开成 Pane"), L("esc 返回")]
    } else {
      hints.append(L("↩ 打开"))
      if selectedRow?.inlineResult != nil { hints.append(L("⌘↩ 预填结果")) }
      hints += [L("⌥↩ 开成 Pane"), "⌘1–9", L("esc 关闭")]
    }
    footer.hints = hints
  }

  /// 按住 ⌘ 时显示结果行的 ⌘1–9 键帽。
  private func setCommandHintsVisible(_ visible: Bool) {
    guard showsCommandHints != visible else { return }
    showsCommandHints = visible
    updateCommandHintAppearance()
  }

  /// 把 ⌘ 键帽的显示状态应用到各结果行。
  private func updateCommandHintAppearance() {
    for (index, rowView) in rowViews.enumerated() {
      rowView.setCommandHint(index < 9 ? "⌘\(index + 1)" : nil, visible: showsCommandHints)
    }
  }
}
