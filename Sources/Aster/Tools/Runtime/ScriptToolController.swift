// 脚本工具在会话里的运行与展示：text 显示输出，list 显示列表（输入变化去抖重跑），none 跑完提示并请求关闭。
// 进程在后台运行；每次运行有代次，旧结果迟到时丢弃，`teardown()` 取消进程且不再回调。
import AppKit
import AsterCore

/// 脚本工具向会话请求的动作。
@MainActor
struct ScriptToolActions {
  let copy: @MainActor (String) -> Void
  let insertIntoTerminal: @MainActor (String) -> Void
  let openInPane: @MainActor () -> Void
  let showNotice: @MainActor (_ text: String, _ isError: Bool) -> Void
  let requestClose: @MainActor () -> Void
  /// 希望的高度或主结果变了。
  let contentDidChange: @MainActor () -> Void
}

/// 运行一个 text / list / none 脚本功能并展示结果。`terminal` 输出不经过这里。
@MainActor
final class ScriptToolController {
  let view = NSView()
  private let action: ToolScriptAction
  private let feature: ToolFeature
  private var plugin: ToolPluginRuntimeInfo?
  private var input: ToolInput
  private let actions: ScriptToolActions
  private var runTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var generation = 0
  private var isTornDown = false
  private var outputText: String?
  private var listView: ScriptToolListView?
  private var currentHeight: CGFloat = 160

  init(action: ToolScriptAction, feature: ToolFeature, plugin: ToolPluginRuntimeInfo, input: ToolInput, actions: ScriptToolActions) {
    self.action = action
    self.feature = feature
    self.plugin = plugin
    self.input = input
    self.actions = actions
  }

  /// 希望的内容高度（点）。
  var preferredHeight: CGFloat { currentHeight }

  /// text 输出的文字，或列表里选中（默认第一项）的值。
  var primaryResultText: String? {
    switch action.output {
    case .text: outputText
    case .list: listView?.selectedValue
    case .none, .terminal: nil
    }
  }

  /// 第一次运行。
  func start() {
    run()
  }

  /// 启动器继续输入：只有 list 去抖重跑（取消旧进程），text / none 不因为打字重复执行。
  func updateQuery(_ input: ToolInput) {
    self.input = input
    guard action.output == .list else { return }
    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(ScriptToolProtocol.listDebounce))
      } catch {
        return
      }
      self?.run()
    }
  }

  /// 换一份输入重新运行（同一工具再次被打开）。
  func rerun(with input: ToolInput) {
    self.input = input
    debounceTask?.cancel()
    run()
  }

  /// 插件状态变化后更新运行信息；nil 表示插件已不可用，之后的重跑改为提示。
  func updatePlugin(_ plugin: ToolPluginRuntimeInfo?) {
    self.plugin = plugin
  }

  /// 取消进程与去抖；之后不再回调。
  func teardown() {
    isTornDown = true
    generation += 1
    runTask?.cancel()
    debounceTask?.cancel()
  }

  // MARK: 运行

  /// 取消上一次运行，按当前输入在后台启动新的一次。
  private func run() {
    guard !isTornDown else { return }
    runTask?.cancel()
    generation += 1
    let generation = generation
    guard let plugin else {
      show(ToolSessionMessageView(text: L("插件已不可用"), style: .error), height: 160)
      return
    }
    // list 重跑时保留旧列表，避免每敲一个字都闪一下。
    if action.output != .list || listView == nil {
      show(ToolSessionRunningView(text: L("正在运行「\(feature.title)」…")), height: currentHeight)
    }
    let action = action
    let code = feature.code
    let input = input
    runTask = Task { [weak self] in
      let result: Result<ScriptToolOutput, ScriptToolError>
      do {
        result = .success(try await Self.execute(action: action, code: code, plugin: plugin, input: input))
      } catch let error as ScriptToolError {
        result = .failure(error)
      } catch {
        result = .failure(.launchFailed(error.localizedDescription))
      }
      guard let self, !self.isTornDown, generation == self.generation else { return }
      self.present(result)
    }
  }

  /// 后台组装并运行。
  @concurrent
  private nonisolated static func execute(
    action: ToolScriptAction, code: String, plugin: ToolPluginRuntimeInfo, input: ToolInput
  ) async throws -> ScriptToolOutput {
    let invocation = try ScriptToolRunner.makeInvocation(
      action: action, code: code, plugin: plugin, input: input, query: input.text)
    return try await ScriptToolRunner.run(invocation)
  }

  /// 按输出模式展示结果。
  private func present(_ result: Result<ScriptToolOutput, ScriptToolError>) {
    switch result {
    case .failure(.cancelled):
      return  // 被新的一次运行取代
    case .failure(let error):
      showError(error.localizedMessage)
    case .success(let output):
      switch action.output {
      case .text:
        presentText(ScriptToolProtocol.decodeText(output.stdout))
      case .list:
        do {
          presentList(try ScriptToolProtocol.parseList(output.stdout))
        } catch let error as ScriptToolError {
          showError(error.localizedMessage)
        } catch {
          showError(error.localizedDescription)
        }
      case .none, .terminal:
        // 先换成完成状态再请求关闭：容器可能在关闭回调里同步 teardown。
        show(ToolSessionMessageView(text: L("已完成"), style: .success), height: 140)
        actions.showNotice(L("已完成"), false)
        actions.requestClose()
      }
    }
  }

  /// 出错：显示原因与「重新运行」。
  private func showError(_ message: String) {
    outputText = nil
    listView = nil
    let view = ToolSessionMessageView(text: message, style: .error, buttonTitle: L("重新运行")) { [weak self] in
      self?.run()
    }
    show(view, height: 200)
  }

  /// text 输出：等宽可选中文本 + 复制 / 预填到终端 / 开成 Pane。
  private func presentText(_ text: String) {
    outputText = text
    let root = BuiltinToolRootView()
    let area = BuiltinTextArea(placeholder: L("（没有输出）"), editable: false)
    area.string = text
    let copy = BuiltinToolLayout.button(L("复制"), symbol: "doc.on.doc") { [weak self] in
      guard let text = self?.outputText else { return }
      self?.actions.copy(text)
    }
    let insert = BuiltinToolLayout.button(L("预填到终端"), symbol: "terminal") { [weak self] in
      guard let text = self?.outputText else { return }
      self?.actions.insertIntoTerminal(text)
    }
    let pane = BuiltinToolLayout.button(L("开成 Pane"), symbol: "rectangle.split.2x1") { [weak self] in
      self?.actions.openInPane()
    }
    let rerun = BuiltinToolLayout.button(L("重新运行"), symbol: "arrow.clockwise") { [weak self] in self?.run() }
    let toolbar = BuiltinToolLayout.toolbar(leading: [rerun], trailing: [copy, insert, pane])
    root.install(arranged: [area, toolbar], expanding: area)
    show(root, height: 280)
  }

  /// list 输出：列表 + 底部提示。已有列表时原地换数据，保留滚动与焦点。
  private func presentList(_ items: [ToolListItem]) {
    if let listView {
      listView.setItems(items)
    } else {
      let list = ScriptToolListView(
        onCopy: { [weak self] value in self?.actions.copy(value) },
        onInsert: { [weak self] value in self?.actions.insertIntoTerminal(value) },
        onSelectionChange: { [weak self] in self?.actions.contentDidChange() })
      list.setItems(items)
      listView = list
      show(list, height: 320)
    }
    actions.contentDidChange()
  }

  /// 换掉当前显示的视图。
  private func show(_ content: NSView, height: CGFloat) {
    if !(content is ScriptToolListView) { listView = nil }
    view.subviews.forEach { $0.removeFromSuperview() }
    view.addSubview(content)
    content.pinEdges(to: view)
    currentHeight = height
    actions.contentDidChange()
  }
}

/// list 输出的列表：标题 + 副标题；↩ 或双击复制该项的值，⌘↩ 预填到终端。
@MainActor
final class ScriptToolListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
  private let tableView = ScriptToolTableView()
  private let scrollView = NSScrollView()
  private let emptyLabel = makeLabel(L("没有结果"), size: 12, color: AsterTheme.secondaryInk)
  private var items: [ToolListItem] = []
  private let onCopy: (String) -> Void
  private let onInsert: (String) -> Void
  private let onSelectionChange: () -> Void

  init(onCopy: @escaping (String) -> Void, onInsert: @escaping (String) -> Void, onSelectionChange: @escaping () -> Void) {
    self.onCopy = onCopy
    self.onInsert = onInsert
    self.onSelectionChange = onSelectionChange
    super.init(frame: .zero)
    let column = NSTableColumn(identifier: .init("item"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .plain
    tableView.backgroundColor = .clear
    tableView.rowHeight = 40
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(copySelected)
    tableView.onActivate = { [weak self] withCommand in
      guard let value = self?.selectedValue else { return }
      if withCommand { self?.onInsert(value) } else { self?.onCopy(value) }
    }
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = tableView
    addSubview(scrollView)
    scrollView.pinEdges(to: self, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
    addSubview(emptyLabel)
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 选中项（没选时第一项）的值。
  var selectedValue: String? {
    let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
    return items.indices.contains(row) ? items[row].resolvedValue : nil
  }

  /// 换一批数据；默认选中第一项。
  func setItems(_ items: [ToolListItem]) {
    self.items = items
    tableView.reloadData()
    emptyLabel.isHidden = !items.isEmpty
    if !items.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
  }

  @objc private func copySelected() {
    guard tableView.clickedRow >= 0, items.indices.contains(tableView.clickedRow) else { return }
    onCopy(items[tableView.clickedRow].resolvedValue)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("script-list-row")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ScriptToolListCell
      ?? ScriptToolListCell(identifier: identifier)
    cell.configure(items[row])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    onSelectionChange()
  }
}

/// 列表的一行：标题一行、副标题一行（没有就只显示标题）。
@MainActor
final class ScriptToolListCell: NSTableCellView {
  private let title = makeLabel("", size: 12, color: AsterTheme.ink)
  private let subtitle = makeLabel("", size: 11, color: AsterTheme.secondaryInk)

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    let stack = NSStackView(views: [title, subtitle])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  required init?(coder: NSCoder) { nil }

  /// 填入一项。
  func configure(_ item: ToolListItem) {
    title.stringValue = item.title
    subtitle.stringValue = item.subtitle ?? ""
    subtitle.isHidden = (item.subtitle ?? "").isEmpty
  }
}

/// 处理 ↩ / ⌘↩ 的表格。
@MainActor
final class ScriptToolTableView: NSTableView {
  /// 回车激活选中项；参数表示是否按住 ⌘。
  var onActivate: ((Bool) -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 {
      onActivate?(event.modifierFlags.contains(.command))
      return
    }
    super.keyDown(with: event)
  }
}
