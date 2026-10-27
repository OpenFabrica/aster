// 端口占用工具：列出本机进程的 TCP 监听端口，可按端口过滤与刷新，确认后结束进程。
import AppKit
import AsterCore
import Darwin

/// 本机监听端口扫描，在并发执行器上运行，不占主线程。
enum BuiltinListeningPorts {
  /// 列出全部进程，交给 `ListeningPortScanner` 读各自的监听 socket；读不到的进程（其他用户的）自动跳过。
  @concurrent
  static func scan() async -> [ListeningPort] {
    let processes = livePIDs().filter { $0 > 0 }.map {
      WorkspaceProcess(processIdentifier: $0, parentProcessIdentifier: 0, command: "")
    }
    return ListeningPortScanner.scan(processes: processes, maximumResults: 1_000)
  }

  /// 全机当前可见的 pid 列表。
  ///
  /// 两个陷阱（与 `ProcessFootprintSampler` 相同）：
  /// 1. `proc_listallpids` 填充时返回的是**写入的 pid 个数**，不是字节数；按字节数除以
  ///    `MemoryLayout<pid_t>.size` 会只剩四分之一的进程。
  /// 2. 两次调用之间可能新建进程，所以缓冲区在容量上多留一截，并按实际个数收口。
  static func livePIDs() -> [pid_t] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return Array(pids.prefix(min(Int(count), pids.count)))
  }
}

/// `ports` 内置工具的界面。
@MainActor
final class PortsToolContent: NSObject, BuiltinToolContent, NSTableViewDataSource, NSTableViewDelegate,
  NSMenuDelegate
{
  /// 表格三列；原始值是列标识。
  private enum Column: String {
    case endpoint
    case pid
    case process
  }

  /// 换输入时上次扫描超过这么久就重扫，连续输入只重新过滤。
  private static let rescanInterval: TimeInterval = 2

  var view: NSView { root }
  var preferredHeight: CGFloat { 380 }
  var primaryResultText: String? { selectedPort.map { String($0.processIdentifier) } }

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let titleLabel = makeLabel("", size: 12, weight: .medium, color: AsterTheme.ink)
  private let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let emptyLabel = makeLabel("", size: 12, color: AsterTheme.secondaryInk)
  private var killButton: NSButton?
  private var allPorts: [ListeningPort] = []
  private var rows: [ListeningPort] = []
  private var portFilter: Int?
  /// 每次扫描加一；只回写最新一次扫描的结果。
  private var generation = 0
  private var scanTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var lastScan: Date?
  private var isScanning = false
  private var lastPrimary: String?
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    super.init()
    let refreshButton = BuiltinToolLayout.button(L("刷新"), symbol: "arrow.clockwise") { [weak self] in
      self?.refresh()
    }
    let terminateButton = BuiltinToolLayout.button(L("结束进程…"), symbol: "xmark.octagon") { [weak self] in
      guard let self, let port = self.selectedPort else { return }
      self.confirmKill(port)
    }
    killButton = terminateButton
    titleLabel.lineBreakMode = .byTruncatingTail
    let toolbar = BuiltinToolLayout.toolbar(leading: [titleLabel], trailing: [refreshButton, terminateButton])
    let card = BuiltinToolCard(content: makeTable(), insets: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
    card.addSubview(emptyLabel)
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: 10),
      emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -32),
    ])
    root.install(arranged: [toolbar, card], expanding: card)
    portFilter = BuiltinPortFilter.port(from: input.text)
    reloadRows()
    refresh()
    isReady = true
  }

  func update(input: ToolInput) {
    guard !isTornDown else { return }
    portFilter = BuiltinPortFilter.port(from: input.text)
    reloadRows()
    if let lastScan, Date().timeIntervalSince(lastScan) > Self.rescanInterval { refresh() }
  }

  func teardown() {
    isTornDown = true
    generation += 1
    scanTask?.cancel()
    refreshTask?.cancel()
    scanTask = nil
    refreshTask = nil
    tableView.dataSource = nil
    tableView.delegate = nil
  }

  // MARK: 表格

  /// 建表：端点、PID、进程三列，透明底放在卡片里；右键菜单按点击行即时生成。
  private func makeTable() -> NSView {
    let columns: [(Column, String, CGFloat)] = [
      (.endpoint, L("端点"), 200), (.pid, "PID", 72), (.process, L("进程名"), 180),
    ]
    for (column, title, width) in columns {
      let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
      tableColumn.title = title
      tableColumn.width = width
      tableColumn.minWidth = 48
      tableView.addTableColumn(tableColumn)
    }
    tableView.style = .plain
    tableView.backgroundColor = .clear
    tableView.rowHeight = 22
    tableView.allowsMultipleSelection = false
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    // 表头右上角的角落视图在卡片里是一块突兀的白方块，不需要。
    tableView.cornerView = nil
    tableView.dataSource = self
    tableView.delegate = self
    tableView.menu = NSMenu()
    tableView.menu?.delegate = self
    tableView.setAccessibilityLabel(L("监听端口"))
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.documentView = tableView
    return scrollView
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue),
      rows.indices.contains(row)
    else { return nil }
    let port = rows[row]
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
    switch column {
    case .endpoint:
      cell.textField?.stringValue = port.endpoint
      cell.textField?.font = NSFont.interfaceMonospacedDigit(ofSize: 12)
      cell.textField?.textColor = AsterTheme.ink
    case .pid:
      cell.textField?.stringValue = String(port.processIdentifier)
      cell.textField?.font = NSFont.interfaceMonospacedDigit(ofSize: 12)
      cell.textField?.textColor = AsterTheme.secondaryInk
    case .process:
      cell.textField?.stringValue = port.processName ?? L("未知进程")
      cell.textField?.font = NSFont.interface(ofSize: 12)
      cell.textField?.textColor = AsterTheme.ink
    }
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateKillButton()
    notifyResultIfChanged()
  }

  /// 单元格：一个截断尾部的标签。
  private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(label)
    cell.textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  /// 右键菜单：点在未选中的行上先选中它；复制端点 / PID，或结束进程。
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let clicked = tableView.clickedRow
    guard rows.indices.contains(clicked) else { return }
    if !tableView.selectedRowIndexes.contains(clicked) {
      tableView.selectRowIndexes([clicked], byExtendingSelection: false)
    }
    let port = rows[clicked]
    menu.addItem(ActionMenuItem(title: L("复制端点")) { [weak self] in self?.actions.copy(port.endpoint) })
    menu.addItem(ActionMenuItem(title: L("复制 PID")) { [weak self] in
      self?.actions.copy(String(port.processIdentifier))
    })
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: L("结束进程…")) { [weak self] in self?.confirmKill(port) })
  }

  // MARK: 扫描

  /// 重新扫描全部监听端口；旧的扫描结果到达时按代次丢弃。
  private func refresh() {
    guard !isTornDown else { return }
    generation += 1
    let current = generation
    scanTask?.cancel()
    isScanning = true
    updateTitle()
    scanTask = Task { [weak self] in
      let ports = await BuiltinListeningPorts.scan()
      self?.applyScan(ports, generation: current)
    }
  }

  /// 扫描结果回到主线程：只认最新一次。
  private func applyScan(_ ports: [ListeningPort], generation: Int) {
    guard generation == self.generation, !isTornDown else { return }
    scanTask = nil
    isScanning = false
    lastScan = Date()
    allPorts = ports
    reloadRows()
  }

  /// 按过滤条件重排表格，尽量保住原来的选中行；过滤到某个端口且只剩一行时直接选中它。
  private func reloadRows() {
    let previous = selectedPort
    rows = BuiltinPortFilter.filtered(allPorts, port: portFilter)
    tableView.reloadData()
    let keep = previous.flatMap { old in
      rows.firstIndex { $0.processIdentifier == old.processIdentifier && $0.endpoint == old.endpoint }
    }
    if let keep {
      tableView.selectRowIndexes([keep], byExtendingSelection: false)
    } else if portFilter != nil, rows.count == 1 {
      tableView.selectRowIndexes([0], byExtendingSelection: false)
    }
    updateTitle()
    updateKillButton()
    notifyResultIfChanged()
  }

  /// 标题：过滤条件与行数；扫描中显示「正在扫描…」。空列表时在卡片中央说明原因。
  private func updateTitle() {
    let scope = portFilter.map { L("端口 \(String($0))") } ?? L("全部监听端口")
    titleLabel.stringValue = isScanning ? L("正在扫描…") : "\(scope) · \(rows.count)"
    let showsEmpty = !isScanning && rows.isEmpty && lastScan != nil
    emptyLabel.isHidden = !showsEmpty
    emptyLabel.stringValue = portFilter.map { L("没有进程在监听端口 \(String($0))") } ?? L("没有找到监听中的 TCP 端口")
  }

  private var selectedPort: ListeningPort? {
    let row = tableView.selectedRow
    return rows.indices.contains(row) ? rows[row] : nil
  }

  private func updateKillButton() {
    killButton?.isEnabled = selectedPort != nil
  }

  /// 主结果（选中行的 PID）变了才通知会话。
  private func notifyResultIfChanged() {
    let current = primaryResultText
    guard current != lastPrimary else { return }
    lastPrimary = current
    if isReady { actions.resultDidChange() }
  }

  // MARK: 结束进程

  /// 先确认再结束：写清进程名、PID 与端点；有窗口挂 sheet，否则模态。
  private func confirmKill(_ port: ListeningPort) {
    guard !isTornDown else { return }
    let pid = port.processIdentifier
    guard pid != getpid() else {
      actions.showNotice(L("不能结束 Aster 自己"), true)
      return
    }
    let name = port.processName ?? L("未知进程")
    let alert = NSAlert()
    alert.messageText = L("结束进程 \(name)（PID \(String(pid))）？")
    alert.informativeText = L("会向它发送 SIGTERM。正在监听 \(port.endpoint) 的服务会停止，未保存的数据可能丢失。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("结束进程"))
    alert.addButton(withTitle: L("取消"))
    let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.terminate(pid: pid, name: name)
    }
    if let window = actions.window() {
      alert.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(alert.runModal())
    }
  }

  /// 发送 SIGTERM；成功或进程已不在时稍后刷新列表。
  private func terminate(pid: pid_t, name: String) {
    guard !isTornDown else { return }
    if Darwin.kill(pid, SIGTERM) == 0 {
      actions.showNotice(L("已向 \(name) 发送结束信号"), false)
      scheduleRefresh()
      return
    }
    let code = errno
    let reason: String =
      switch code {
      case EPERM: L("没有权限结束这个进程")
      case ESRCH: L("进程已经退出")
      default: String(cString: strerror(code))
      }
    actions.showNotice(L("结束进程失败：\(reason)"), true)
    if code == ESRCH { scheduleRefresh() }
  }

  /// 0.5 秒后刷新：给进程一点时间退出并释放端口。
  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return  // 已取消（关闭工具或又安排了一次刷新），不再刷新。
      }
      self?.refresh()
    }
  }
}
