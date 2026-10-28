// 「便笺」内置工具的界面：便笺列表（色块、第一行、修改时间），新建、全部显示、全部收起与删除。
// 便笺本身是桌面上的独立窗口（StickyNoteCenter）；这里只是入口与目录。启动器继续输入的文字用来筛选列表，
// 也是「新建便笺」的初始内容。
import AppKit
import AsterCore
import Combine

/// `stickies` 内置工具的界面。
@MainActor
final class StickiesToolContent: NSObject, BuiltinToolContent, NSTableViewDataSource, NSTableViewDelegate,
  NSMenuDelegate
{
  var view: NSView { root }
  var preferredHeight: CGFloat { 360 }
  /// 选中便笺的全文（`⌘↩` 预填到终端）。
  var primaryResultText: String? { selectedNote.map(\.text).flatMap { $0.isEmpty ? nil : $0 } }

  private let actions: BuiltinToolActions
  private let center: StickyNoteCenter
  private let root = BuiltinToolRootView()
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let emptyLabel = makeLabel("", size: 12, color: AsterTheme.secondaryInk)
  private var deleteButton: NSButton?
  private var rows: [StickyNote] = []
  private var query = ""
  private var subscription: AnyCancellable?
  private var isTornDown = false
  private var lastPrimary: String?

  init(input: ToolInput, actions: BuiltinToolActions, center: StickyNoteCenter = .shared) {
    self.actions = actions
    self.center = center
    super.init()
    let newButton = BuiltinToolLayout.button(L("新建便笺"), symbol: "plus") { [weak self] in self?.createNote() }
    let showAll = BuiltinToolLayout.button(L("全部显示"), symbol: "macwindow.on.rectangle") { [weak center] in
      center?.showAll()
    }
    let hideAll = BuiltinToolLayout.button(L("全部收起"), symbol: "eye.slash") { [weak center] in center?.hideAll() }
    let remove = BuiltinToolLayout.button(L("删除…"), symbol: "trash") { [weak self] in self?.confirmDeleteSelected() }
    deleteButton = remove
    let toolbar = BuiltinToolLayout.toolbar(leading: [newButton], trailing: [showAll, hideAll, remove])
    let card = BuiltinToolCard(content: makeTable(), insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
    card.addSubview(emptyLabel)
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -32),
    ])
    root.install(arranged: [toolbar, card], expanding: card)
    query = input.text ?? ""
    subscription = center.changes.sink { [weak self] in self?.reloadRows() }
    reloadRows()
  }

  func update(input: ToolInput) {
    guard !isTornDown else { return }
    query = input.text ?? ""
    reloadRows()
  }

  func teardown() {
    isTornDown = true
    subscription = nil
    tableView.dataSource = nil
    tableView.delegate = nil
  }

  // MARK: 表格

  /// 单列列表：色块 + 第一行 + 修改时间；双击或回车显示便笺，右键菜单显示 / 删除。
  private func makeTable() -> NSView {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .plain
    tableView.backgroundColor = .clear
    tableView.rowHeight = 40
    tableView.allowsMultipleSelection = false
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(showClickedNote)
    tableView.menu = NSMenu()
    tableView.menu?.delegate = self
    tableView.setAccessibilityLabel(L("便笺"))
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = tableView
    return scrollView
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("StickyNoteCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? StickyNoteListCell
      ?? StickyNoteListCell(identifier: identifier)
    cell.configure(note: rows[row])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    deleteButton?.isEnabled = selectedNote != nil
    notifyResultIfChanged()
  }

  /// 右键菜单：点在未选中的行上先选中它。
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let clicked = tableView.clickedRow
    guard rows.indices.contains(clicked) else { return }
    tableView.selectRowIndexes([clicked], byExtendingSelection: false)
    let note = rows[clicked]
    menu.addItem(ActionMenuItem(title: L("显示便笺")) { [weak center] in center?.show(id: note.id) })
    if !note.text.isEmpty {
      menu.addItem(ActionMenuItem(title: L("复制内容")) { [weak self] in self?.actions.copy(note.text) })
    }
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: L("删除便笺…")) { [weak self] in self?.confirmDelete(note) })
  }

  // MARK: 动作

  private var selectedNote: StickyNote? {
    rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow] : nil
  }

  /// 双击一行：显示那张便笺。
  @objc private func showClickedNote() {
    let row = tableView.clickedRow
    guard rows.indices.contains(row) else { return }
    center.show(id: rows[row].id)
  }

  /// 新建便笺；搜索框里有文字时用它做初始内容。
  private func createNote() {
    guard !isTornDown else { return }
    center.createNote(text: query.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// 工具条「删除…」：删除选中的便笺。
  private func confirmDeleteSelected() {
    guard let note = selectedNote else { return }
    confirmDelete(note)
  }

  /// 删除前确认；空便笺直接删。
  private func confirmDelete(_ note: StickyNote) {
    guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      center.delete(id: note.id)
      return
    }
    let alert = NSAlert()
    alert.messageText = L("删除这张便笺？")
    alert.informativeText = L("「\(note.title)」删除后无法恢复。")
    alert.addButton(withTitle: L("删除"))
    alert.addButton(withTitle: L("取消"))
    alert.buttons.first?.hasDestructiveAction = true
    let handler: (NSApplication.ModalResponse) -> Void = { [weak center] response in
      guard response == .alertFirstButtonReturn else { return }
      MainActor.assumeIsolated { center?.delete(id: note.id) }
    }
    if let window = actions.window() {
      alert.beginSheetModal(for: window, completionHandler: handler)
    } else {
      handler(alert.runModal())
    }
  }

  // MARK: 刷新

  /// 按查询重排列表，尽量保住原来的选中行。
  private func reloadRows() {
    guard !isTornDown else { return }
    let previous = selectedNote?.id
    let all = center.notes
    rows = all.filter { $0.matches(query) }
    tableView.reloadData()
    if let previous, let index = rows.firstIndex(where: { $0.id == previous }) {
      tableView.selectRowIndexes([index], byExtendingSelection: false)
    }
    if rows.isEmpty {
      emptyLabel.stringValue = all.isEmpty ? L("还没有便笺。点「新建便笺」开始写。") : L("没有包含这些文字的便笺")
      emptyLabel.isHidden = false
    } else {
      emptyLabel.isHidden = true
    }
    deleteButton?.isEnabled = selectedNote != nil
    notifyResultIfChanged()
  }

  /// 主结果变化时告诉会话（底部按钮与 `⌘↩` 跟着更新）。
  private func notifyResultIfChanged() {
    let primary = primaryResultText
    guard primary != lastPrimary else { return }
    lastPrimary = primary
    actions.resultDidChange()
  }
}

/// 便笺列表的一行：色块、第一行文字（空便笺显示占位）、修改时间与是否收起。
@MainActor
private final class StickyNoteListCell: NSTableCellView {
  private let swatch = NSImageView()
  private let titleLabel = makeLabel("", size: 12, weight: .medium, color: AsterTheme.ink)
  private let detailLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)

  /// 竖排标题与说明，左侧色块。
  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    titleLabel.lineBreakMode = .byTruncatingTail
    detailLabel.lineBreakMode = .byTruncatingTail
    let text = NSStackView(views: [titleLabel, detailLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1
    let row = NSStackView(views: [swatch, text])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      swatch.widthAnchor.constraint(equalToConstant: 14),
      swatch.heightAnchor.constraint(equalToConstant: 14),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 填入一张便笺。
  func configure(note: StickyNote) {
    swatch.image = StickyNotePalette.swatch(note.color, diameter: 14)
    let title = note.title
    titleLabel.stringValue = title.isEmpty ? L("空白便笺") : title
    titleLabel.textColor = title.isEmpty ? AsterTheme.secondaryInk : AsterTheme.ink
    let date = note.modifiedAt.formatted(date: .abbreviated, time: .shortened)
    detailLabel.stringValue = note.isOpen ? date : L("\(date) · 已收起")
  }
}
