// File Pane 的 JSON 树视图：原生 NSOutlineView 按需展开，大文档也只为可见行建视图。
import AppKit
import AsterCore

/// 树中的一行。子项在首次展开时才创建并缓存，避免为几万个节点预先建对象。
/// 非空容器的最后一个子项是“闭合括号行”，只在容器展开时可见。
@MainActor
final class JSONTreeItem: NSObject {
  /// 根节点为 nil；其余是对象键或数组下标。
  let component: JSONPathComponent?
  let node: JSONNode
  let path: [JSONPathComponent]
  /// 按位置拼成的稳定标识，用于重渲染后恢复展开状态；对象允许重复键，所以不用键名。
  let stateKey: String
  /// 闭合括号行：显示所属容器的 `}` / `]`，不参与复制和选择。
  let isClosing: Bool
  private var cachedChildren: [JSONTreeItem]?

  init(component: JSONPathComponent?, node: JSONNode, path: [JSONPathComponent], stateKey: String,
    isClosing: Bool = false)
  {
    self.component = component
    self.node = node
    self.path = path
    self.stateKey = stateKey
    self.isClosing = isClosing
  }

  /// 有子项、可展开的容器；空容器 `{}` / `[]` 按普通值显示。
  var isExpandable: Bool { !isClosing && (node.childCount ?? 0) > 0 }

  var children: [JSONTreeItem] {
    if let cachedChildren { return cachedChildren }
    var built: [JSONTreeItem]
    switch node {
    case .object(let members):
      built = members.enumerated().map { offset, member in
        JSONTreeItem(component: .key(member.key), node: member.value,
          path: path + [.key(member.key)], stateKey: stateKey + "/\(offset)")
      }
    case .array(let items):
      built = items.enumerated().map { offset, value in
        JSONTreeItem(component: .index(offset), node: value,
          path: path + [.index(offset)], stateKey: stateKey + "/\(offset)")
      }
    default:
      built = []
    }
    if isExpandable {
      built.append(JSONTreeItem(component: nil, node: node, path: path,
        stateKey: stateKey + "/end", isClosing: true))
    }
    cachedChildren = built
    return built
  }

  /// “复制值”的文本：标量复制原值（字符串不带引号），容器复制格式化后的 JSON 片段。
  var valueText: String {
    switch node {
    case .string(let value): value
    case .number(let raw): raw
    case .bool(let value): value ? "true" : "false"
    case .null: "null"
    case .object, .array: JSONDocumentFormatter.serialize(node, indent: "  ")
    }
  }

  var keyText: String? {
    switch component {
    case .key(let key): key
    case .index(let index): String(index)
    case nil: nil
    }
  }
}

/// 把 ⌘C 交给树视图复制所选值，并让闭合括号行与父行的文字左对齐。
@MainActor
final class JSONOutlineView: NSOutlineView {
  var onCopy: (() -> Void)?

  @objc func copy(_ sender: Any?) { onCopy?() }

  /// 闭合括号行在大纲里是容器的子项，会多缩进一级；左移一级后与 `"键" : {` 的起点对齐。
  override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
    var frame = super.frameOfCell(atColumn: column, row: row)
    if (item(atRow: row) as? JSONTreeItem)?.isClosing == true {
      frame.origin.x -= indentationPerLevel
      frame.size.width += indentationPerLevel
    }
    return frame
  }
}

/// 行内文字标签。不参与命中测试：否则右键、点击落在文字上时被标签吃掉，
/// 大纲拿不到事件，右键菜单只在行的空白处才出现，点文字也选不中行。
@MainActor
final class JSONRowLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// JSON Preview 内容视图：顶部是标题和“全部展开 / 全部折叠”，下方圆角卡片里是树；
/// 解析失败时显示带行列的错误和“查看源码”。
@MainActor
final class FileJSONTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
  /// 根下子项不超过这个数量时默认把它们展开一层；根是长数组时保持收起，避免首屏卡顿。
  private static let autoExpandLimit = 50
  /// 行内只显示字符串前缀；完整值通过“复制值”获取。
  private static let displayedStringLimit = 300

  let outlineView = JSONOutlineView()
  private let scrollView = NSScrollView()
  private let header = NSStackView()
  private let titleLabel = NSTextField(labelWithString: L("树视图"))
  private let card = NSView()
  private let errorView = NSStackView()
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private var roots: [JSONTreeItem] = []
  private var hasLoaded = false
  private var theme: TerminalTheme
  private var font: NSFont
  var onShowSource: (() -> Void)?
  var onSendToChat: (() -> Void)?
  var fileActionsMenu: (() -> NSMenu)?

  init(theme: TerminalTheme, font: NSFont) {
    self.theme = theme
    self.font = font
    super.init(frame: .zero)
    identifier = .init("file-pane-json-tree")
    wantsLayer = true
    configureOutline()
    configureLayout()
    configureErrorView()
    apply(theme: theme, font: font)
  }

  required init?(coder: NSCoder) { nil }

  private func configureOutline() {
    let column = NSTableColumn(identifier: .init("json"))
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.style = .plain
    outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    outlineView.indentationPerLevel = 18
    outlineView.autoresizesOutlineColumn = false
    outlineView.allowsMultipleSelection = true
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.menu = NSMenu()
    outlineView.menu?.delegate = self
    outlineView.onCopy = { [weak self] in self?.copySelection(\.valueText) }
    outlineView.setAccessibilityLabel(L("JSON 树"))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = outlineView
  }

  /// 标题栏与 Pane 工具栏同底色；树放进带细边框的圆角卡片，与参考的 Tree View 布局一致。
  private func configureLayout() {
    titleLabel.font = NSFont.interface(ofSize: 13, weight: .semibold)
    titleLabel.textColor = AsterTheme.secondaryInk
    let expand = ActionButton(title: L("全部展开"), bezelStyle: .accessoryBarAction) { [weak self] in
      self?.expandAll()
    }
    let collapse = ActionButton(title: L("全部折叠"), bezelStyle: .accessoryBarAction) { [weak self] in
      self?.collapseAll()
    }
    for (button, id) in [(expand, "file-pane-json-expand-all"), (collapse, "file-pane-json-collapse-all")] {
      button.identifier = .init(id)
      button.controlSize = .small
      button.font = NSFont.interface(ofSize: 11)
    }
    header.setViews([titleLabel, NSView(), expand, collapse], in: .leading)
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    card.wantsLayer = true
    card.layer?.cornerRadius = 8
    card.layer?.borderWidth = 1
    card.layer?.masksToBounds = true
    card.addSubview(scrollView)
    scrollView.pinEdges(to: card, insets: NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4))
    for view in [header, card] {
      addSubview(view)
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      header.heightAnchor.constraint(equalToConstant: 26),
      card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
  }

  /// 错误态与 File Pane 其他空状态一致：居中图标、说明和一个回到源码的按钮。
  private func configureErrorView() {
    let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle",
      accessibilityDescription: nil) ?? NSImage())
    errorLabel.alignment = .center
    errorLabel.font = NSFont.interface(ofSize: NSFont.systemFontSize)
    errorLabel.textColor = AsterTheme.secondaryInk
    let button = ActionButton(title: L("查看源码"), bezelStyle: .rounded) { [weak self] in
      self?.onShowSource?()
    }
    errorView.setViews([icon, errorLabel, button], in: .center)
    errorView.orientation = .vertical
    errorView.alignment = .centerX
    errorView.spacing = 10
    errorView.isHidden = true
    addSubview(errorView)
    errorView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      errorView.centerXAnchor.constraint(equalTo: centerXAnchor),
      errorView.centerYAnchor.constraint(equalTo: centerYAnchor),
      errorView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
    ])
  }

  /// 应用新的解析结果。再次渲染（编辑或磁盘重载）时按位置恢复原来的展开状态。
  func update(result: Result<JSONNode, JSONParseError>) {
    switch result {
    case .failure(let error):
      errorLabel.stringValue = error.localizedSummary
      errorView.isHidden = false
      header.isHidden = true
      card.isHidden = true
    case .success(let node):
      let expanded = hasLoaded ? expandedStateKeys() : nil
      let root = JSONTreeItem(component: nil, node: node, path: [], stateKey: "")
      roots = [root]
      outlineView.reloadData()
      if let expanded {
        restoreExpansion(roots, keys: expanded)
      } else if root.isExpandable {
        outlineView.expandItem(root)
        let children = root.children.filter { !$0.isClosing }
        if children.count <= Self.autoExpandLimit {
          for item in children where item.isExpandable { outlineView.expandItem(item) }
        }
      }
      hasLoaded = true
      errorView.isHidden = true
      header.isHidden = false
      card.isHidden = false
    }
  }

  /// 主题或终端字体变化时就地刷新可见行，不重建树，展开与选择状态保持不变。
  func apply(theme: TerminalTheme, font: NSFont) {
    self.theme = theme
    self.font = font
    let background = NSColor(theme.palette.renderedTerminalBackground)
    layer?.backgroundColor = NSColor(theme.resolvedColor(forSlot: "container.background")
      ?? theme.style.container.background ?? theme.palette.containerBackground).cgColor
    card.layer?.backgroundColor = background.cgColor
    card.layer?.borderColor = foreground.withAlphaComponent(0.18).cgColor
    scrollView.backgroundColor = background
    outlineView.backgroundColor = background
    outlineView.rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 8
    if outlineView.numberOfRows > 0 {
      outlineView.reloadData(forRowIndexes: IndexSet(0..<outlineView.numberOfRows), columnIndexes: [0])
    }
  }

  /// 发送到 Chat 用的选区：每个选中行一条 `路径 = 值`；没有选择时返回 nil。
  func selectionTextForChat() -> String? {
    let items = selectedItems()
    guard !items.isEmpty else { return nil }
    return items.map { "\(JSONPath.string($0.path)) = \($0.valueText)" }.joined(separator: "\n")
  }

  func expandAll() { outlineView.expandItem(nil, expandChildren: true) }

  func collapseAll() { outlineView.collapseItem(nil, collapseChildren: true) }

  // MARK: - Data source

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item = item as? JSONTreeItem else { return roots.count }
    return item.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let item = item as? JSONTreeItem else { return roots[index] }
    return item.children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? JSONTreeItem)?.isExpandable == true
  }

  // MARK: - Delegate

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let item = item as? JSONTreeItem else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("json-row")
    let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? makeCell(identifier)
    cell.textField?.attributedStringValue = rowText(for: item)
    cell.toolTip = item.isClosing ? nil : JSONPath.string(item.path)
    return cell
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    (item as? JSONTreeItem)?.isClosing != true
  }

  /// 容器行的文字随展开状态变化（`{` 与 `{…}`），展开或折叠后只重绘这一行。
  func outlineViewItemDidExpand(_ notification: Notification) { reloadRow(for: notification) }

  func outlineViewItemDidCollapse(_ notification: Notification) { reloadRow(for: notification) }

  private func reloadRow(for notification: Notification) {
    guard let item = notification.userInfo?["NSObject"] as? JSONTreeItem else { return }
    outlineView.reloadItem(item, reloadChildren: false)
  }

  private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = JSONRowLabel(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    cell.addSubview(label)
    cell.textField = label
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  /// 行文本按参考样式：`"键" : 值`，键与下标红、字符串绿、数字蓝、布尔与 null 用正文色、
  /// 标点灰。展开的容器只显示开括号，闭括号由单独的闭合行显示；折叠时显示 `{…}` 和子项数。
  private func rowText(for item: JSONTreeItem) -> NSAttributedString {
    let text = NSMutableAttributedString()
    func append(_ string: String, _ color: NSColor) {
      text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
    }
    let (open, close) = brackets(of: item.node)
    if item.isClosing {
      append(close, punctuation)
      return text
    }
    switch item.component {
    case .key(let key): append(JSONDocumentFormatter.quoted(key), ansi(1))
    case .index(let index): append(String(index), ansi(1))
    case nil: append("root", ansi(1))
    }
    append(" : ", punctuation)
    switch item.node {
    case .object, .array:
      let count = item.node.childCount ?? 0
      if count == 0 {
        append(open + close, punctuation)
      } else if outlineView.isItemExpanded(item) {
        append(open, punctuation)
      } else {
        append(open + "…" + close, punctuation)
        append("  " + L("\(String(count)) 项"), punctuation)
      }
    case .string(let value):
      let shown = value.count > Self.displayedStringLimit
        ? String(value.prefix(Self.displayedStringLimit)) + "…" : value
      append(JSONDocumentFormatter.quoted(shown), ansi(2))
    case .number(let raw): append(raw, ansi(4))
    case .bool(let value): append(value ? "true" : "false", foreground)
    case .null: append("null", foreground)
    }
    return text
  }

  private func brackets(of node: JSONNode) -> (String, String) {
    if case .array = node { return ("[", "]") }
    return ("{", "}")
  }

  private var foreground: NSColor { NSColor(theme.palette.foreground) }

  /// 标点用半透明正文色：ANSI 8 在部分浅色主题里接近黑色，达不到“灰色标点”的层次。
  private var punctuation: NSColor { foreground.withAlphaComponent(0.5) }

  private func ansi(_ index: Int) -> NSColor {
    let colors = theme.palette.ansiColors
    return colors.indices.contains(index) ? NSColor(colors[index]) : foreground
  }

  // MARK: - Context menu

  /// 右键菜单按点击行即时构建；点在未选中的行上时先选中它，与 Finder 的行为一致。
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.autoenablesItems = false
    let clicked = outlineView.clickedRow
    if clicked >= 0, !outlineView.selectedRowIndexes.contains(clicked),
      (outlineView.item(atRow: clicked) as? JSONTreeItem)?.isClosing == false
    {
      outlineView.selectRowIndexes([clicked], byExtendingSelection: false)
    }
    let hasSelection = !selectedItems().isEmpty
    func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
      let item = ActionMenuItem(title: title, handler: action)
      item.isEnabled = enabled
      menu.addItem(item)
    }
    add(L("复制值"), enabled: hasSelection) { [weak self] in self?.copySelection(\.valueText) }
    add(L("复制键"), enabled: selectedItems().contains { $0.keyText != nil }) { [weak self] in
      self?.copySelection { $0.keyText }
    }
    add(L("复制路径"), enabled: hasSelection) { [weak self] in
      self?.copySelection { JSONPath.string($0.path) }
    }
    menu.addItem(.separator())
    add(L("全部展开")) { [weak self] in self?.expandAll() }
    add(L("全部折叠")) { [weak self] in self?.collapseAll() }
    menu.addItem(.separator())
    add(L("发送到 Chat") + "…") { [weak self] in self?.onSendToChat?() }
    if let actions = fileActionsMenu?(), !actions.items.isEmpty {
      menu.addItem(.separator())
      for item in actions.items { actions.removeItem(item); menu.addItem(item) }
    }
  }

  private func selectedItems() -> [JSONTreeItem] {
    outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? JSONTreeItem }
      .filter { !$0.isClosing }
  }

  /// 多选时每行一条，按显示顺序用换行连接。
  private func copySelection(_ text: (JSONTreeItem) -> String?) {
    let values = selectedItems().compactMap(text)
    guard !values.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
  }

  // MARK: - Expansion state

  private func expandedStateKeys() -> Set<String> {
    var keys: Set<String> = []
    for row in 0..<outlineView.numberOfRows {
      if let item = outlineView.item(atRow: row) as? JSONTreeItem, outlineView.isItemExpanded(item) {
        keys.insert(item.stateKey)
      }
    }
    return keys
  }

  private func restoreExpansion(_ items: [JSONTreeItem], keys: Set<String>) {
    for item in items where item.isExpandable && keys.contains(item.stateKey) {
      outlineView.expandItem(item)
      restoreExpansion(item.children, keys: keys)
    }
  }
}

extension JSONParseError {
  /// 界面用的错误说明（含行列），树视图与格式化提示共用。
  var localizedSummary: String {
    let reasonText = switch reason {
    case .unexpectedEnd: L("文件意外结束")
    case .unexpectedCharacter: L("意外的字符")
    case .invalidString: L("字符串无效")
    case .invalidNumber: L("数字无效")
    case .tooDeep: L("嵌套层级过深")
    case .trailingContent: L("末尾有多余内容")
    case .cancelled: L("已取消")
    }
    return L("JSON 无效：第 \(String(line)) 行第 \(String(column)) 列，\(reasonText)")
  }
}
