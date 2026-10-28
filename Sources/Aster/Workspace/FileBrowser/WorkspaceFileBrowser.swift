import AppKit
import AsterCore
import Combine

/// 工作区文件浏览器控制器；由中央 Pane 内容按需挂载。
/// 选中图片时下半区内嵌预览，↑/↓ 换行即换图；双击仍在右侧打开文件。

@MainActor
final class FileBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  NSMenuDelegate
{
  private let runtime: WorkspacePaneRuntime
  private weak var tab: TerminalTabItem?
  private let model: AppModel
  private var directory: URL
  private var entries: [URL] = []
  private let table = NSTableView()
  private let imagePreview = FileBrowserImagePreview()
  /// 预览区占可用高度的比例；没选中图片时改用零高度约束把它收起，列表占满。
  private var previewHeightConstraint: NSLayoutConstraint?
  private var previewCollapsedConstraint: NSLayoutConstraint?

  init(runtime: WorkspacePaneRuntime, tab: TerminalTabItem, model: AppModel) {
    self.runtime = runtime
    self.tab = tab
    self.model = model
    directory = URL(
      fileURLWithPath: runtime.descriptor.resourcePath ?? runtime.descriptor.workingDirectory)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  /// Pane 获得焦点时应接收键盘的视图：列表拿到焦点后 ↑/↓ 才能直接切换文件。
  var preferredKeyView: NSView { table }

  /// 搭建文件浏览器：顶部返回/刷新工具条，下面是当前目录的文件表格。
  override func loadView() {
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = AsterTheme.panel.cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    let back = ActionButton(symbol: "chevron.left") { [weak self] in self?.goUp() }
    let refresh = ActionButton(symbol: "arrow.clockwise") { [weak self] in self?.reload() }
    let title = makeLabel(directory.lastPathComponent, size: 11, weight: .semibold)
    let row = NSStackView(views: [back, title, NSView(), refresh])
    row.orientation = .horizontal
    row.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
    toolbar.addSubview(row)
    row.pinEdges(to: toolbar)
    column.addArrangedSubview(toolbar)

    table.headerView = nil
    // 沿用表格默认行高，只按界面字号放大，免得放大后的文件名被行高截掉。
    table.rowHeight = InterfaceScale.length(table.rowHeight)
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openSelected)
    table.backgroundColor = AsterTheme.paper
    let contextMenu = NSMenu()
    contextMenu.delegate = self
    table.menu = contextMenu
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    column.addArrangedSubview(makeBody(list: scroll))
    view = column
    reload(selectingFirstImage: true)
  }

  /// 列表在上、图片预览在下。预览区用两条互斥的高度约束切换展开 / 收起，
  /// 不放进 NSStackView：隐藏的子视图会被栈视图摘下，跨视图的比例约束随之失效。
  private func makeBody(list: NSView) -> NSView {
    let body = NSView()
    for view in [list, imagePreview] {
      view.translatesAutoresizingMaskIntoConstraints = false
      body.addSubview(view)
    }
    let expanded = imagePreview.heightAnchor.constraint(equalTo: body.heightAnchor, multiplier: 0.62)
    let collapsed = imagePreview.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: body.topAnchor),
      list.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      list.bottomAnchor.constraint(equalTo: imagePreview.topAnchor),
      imagePreview.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      imagePreview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      imagePreview.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      collapsed,
    ])
    previewHeightConstraint = expanded
    previewCollapsedConstraint = collapsed
    imagePreview.isHidden = true
    return body
  }

  /// 选中行变化（点击或 ↑/↓）时刷新预览。
  func tableViewSelectionDidChange(_ notification: Notification) {
    updatePreview()
  }

  /// 选中的是图片就展开预览并加载，否则收起预览、列表占满。
  private func updatePreview() {
    let row = table.selectedRow
    guard entries.indices.contains(row), FileBrowserImagePreview.canPreview(entries[row]) else {
      setPreviewVisible(false)
      imagePreview.clear()
      return
    }
    setPreviewVisible(true)
    // 先让预览区拿到展开后的尺寸，降采样才按真实大小计算。
    view.layoutSubtreeIfNeeded()
    imagePreview.show(entries[row])
  }

  private func setPreviewVisible(_ visible: Bool) {
    guard imagePreview.isHidden == visible else { return }
    imagePreview.isHidden = !visible
    // 先停用再启用，避免两条高度约束同时生效产生冲突。
    if visible {
      previewCollapsedConstraint?.isActive = false
      previewHeightConstraint?.isActive = true
    } else {
      previewHeightConstraint?.isActive = false
      previewCollapsedConstraint?.isActive = true
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard entries.indices.contains(row) else { return nil }
    let url = entries[row]
    let cell = NSTableCellView()
    let directory = isDirectory(url)
    let image = NSImageView(
      image: NSImage(systemSymbolName: directory ? "folder" : "doc", accessibilityDescription: nil)
        ?? NSImage())
    image.contentTintColor = directory ? AsterTheme.accent : AsterTheme.secondaryInk
    let label = makeLabel(url.lastPathComponent, size: 11.5)
    let stack = NSStackView(views: [image, label])
    stack.orientation = .horizontal
    stack.spacing = 8
    cell.addSubview(stack)
    stack.pinEdges(to: cell, insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
    return cell
  }

  /// 重新读取当前目录。刷新时尽量保留原来选中的文件；
  /// 进入新目录时（`selectingFirstImage`）默认选中第一张图片，打开图片目录就能直接看图。
  private func reload(selectingFirstImage: Bool = false) {
    let previous = entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ).sorted {
        let left = isDirectory($0)
        let right = isDirectory($1)
        return left == right
          ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
          : left
      }
    } catch { entries = [] }
    table.reloadData()
    let target = selectingFirstImage
      ? entries.firstIndex(where: FileBrowserImagePreview.canPreview)
      : previous.flatMap { entries.firstIndex(of: $0) }
    if let target {
      table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
      table.scrollRowToVisible(target)
    } else {
      table.deselectAll(nil)
    }
    updatePreview()
  }

  private func goUp() {
    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else { return }
    directory = parent
    reload(selectingFirstImage: true)
  }

  @objc private func openSelected() {
    guard entries.indices.contains(table.selectedRow) else { return }
    let url = entries[table.selectedRow]
    if isDirectory(url) {
      directory = url
      reload(selectingFirstImage: true)
    } else {
      tab?.openFile(url)
    }
  }

  /// 根据当前右键命中的行动态生成菜单，避免在目录刷新后菜单仍引用失效 URL。
  func menuWillOpen(_ menu: NSMenu) {
    menu.removeAllItems()
    let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    guard entries.indices.contains(row) else { return }
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    let url = entries[row]
    menu.addItem(
      ActionMenuItem(title: isDirectory(url) ? L("打开文件夹") : L("打开")) { [weak self] in
        self?.openURL(url)
      })
    if !isDirectory(url) {
      menu.addItem(
        ActionMenuItem(title: L("在预览中打开")) { [weak self] in
          self?.tab?.openPreview(url)
        })
      menu.addItem(
        ActionMenuItem(title: L("发送到 Chat")) { [weak self] in
          self?.model.sendFileToChat(url)
        })
    }
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("复制绝对路径")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
      })
    menu.addItem(
      ActionMenuItem(title: L("在新终端中打开所在目录")) { [weak tab] in
        let directory = self.isDirectory(url) ? url.path : url.deletingLastPathComponent().path
        tab?.split(direction: .right, workingDirectory: directory)
      })
    menu.addItem(
      ActionMenuItem(title: L("在当前终端中 cd 到所在目录")) { [weak tab] in
        let directory = self.isDirectory(url) ? url.path : url.deletingLastPathComponent().path
        _ = tab?.openDirectoryInTerminal(directory)
      })
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("在 Finder 中显示")) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      })
    menu.addItem(
      ActionMenuItem(title: L("使用默认应用打开")) {
        NSWorkspace.shared.open(url)
      })
  }

  private func openURL(_ url: URL) {
    if isDirectory(url) {
      directory = url
      reload(selectingFirstImage: true)
    } else {
      tab?.openFile(url)
    }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

/// Open Quickly 展示时覆盖工作区的轻量 scrim。点击浮层外部关闭，但不抢占
/// 面板内部的鼠标和键盘事件。
