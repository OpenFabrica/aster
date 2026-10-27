// JSON 工具：输入区 + 树视图 / 格式化 / 压缩三种结果。解析在后台进行，按代次回写，旧解析随新输入取消。
import AppKit
import AsterCore

/// 一次后台解析的产物：树，以及合法时的格式化与压缩文本。
struct BuiltinJSONRender: Sendable {
  let tree: Result<JSONNode, JSONParseError>
  let formatted: String?
  let minified: String?

  /// 解析并生成两种排版；任务被取消时返回 nil（调用方直接丢弃）。输入最多 1 MiB，放在并发执行器上做。
  @concurrent
  static func render(_ text: String) async -> BuiltinJSONRender? {
    do {
      let node = try JSONDocumentParser.parse(text)
      try Task.checkCancellation()
      let formatted = try JSONDocumentFormatter.format(text, indent: "  ")
      try Task.checkCancellation()
      let minified = try JSONDocumentFormatter.minify(text)
      return BuiltinJSONRender(tree: .success(node), formatted: formatted, minified: minified)
    } catch let error as JSONParseError {
      return error.reason == .cancelled ? nil : BuiltinJSONRender(tree: .failure(error), formatted: nil, minified: nil)
    } catch {
      return nil  // 只剩 CancellationError：任务已取消，结果作废。
    }
  }
}

/// `json` 内置工具的界面。
@MainActor
final class JSONToolContent: BuiltinToolContent {
  /// 三种结果视图；原始值是分段控件的下标。
  private enum Mode: Int {
    case tree
    case formatted
    case minified
  }

  /// 输入区编辑后等这么久再解析，连续输入不反复解析大文档。
  private static let editDebounce: Duration = .milliseconds(250)

  var view: NSView { root }
  var preferredHeight: CGFloat { 440 }
  var primaryResultText: String? { mode == .minified ? rendered?.minified : rendered?.formatted }

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let segments = BuiltinSegmentedControl(labels: [L("树"), L("格式化"), L("压缩")])
  private let inputArea = BuiltinTextArea(placeholder: L("粘贴 JSON 文本"), editable: true)
  private let treeView: FileJSONTreeView
  private let outputArea: BuiltinTextArea
  /// 结果区：树与文本叠放，按模式切换显隐。
  private let resultArea = NSView()
  private let hint = BuiltinToolLayout.hintLabel()
  private var mode = Mode.tree
  private var rendered: BuiltinJSONRender?
  /// 每次换输入加一；只回写最新一次解析。
  private var generation = 0
  private var renderTask: Task<Void, Never>?
  private var debounceTask: Task<Void, Never>?
  private var lastPrimary: String?
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    let style = actions.terminalStyle()
    treeView = FileJSONTreeView(theme: style.theme, font: style.font)
    treeView.appearance = Self.treeAppearance(for: style.theme)
    outputArea = BuiltinTextArea(placeholder: "", editable: false, font: style.font)
    BuiltinToolLayout.fixHeight(inputArea, 76)
    for view in [treeView, outputArea] as [NSView] {
      resultArea.addSubview(view)
      view.pinEdges(to: resultArea)
    }
    let copy = BuiltinToolLayout.button(L("复制"), symbol: "doc.on.doc") { [weak self] in self?.copyResult() }
    let toolbar = BuiltinToolLayout.toolbar(leading: [segments], trailing: [copy])
    root.install(arranged: [toolbar, inputArea, resultArea, hint], expanding: resultArea)
    segments.selectedSegment = Mode.tree.rawValue
    segments.onChange = { [weak self] index in
      guard let mode = Mode(rawValue: index) else { return }
      self?.select(mode)
    }
    inputArea.onChange = { [weak self] _ in self?.scheduleRender() }
    treeView.onShowSource = { [weak self] in self?.select(.formatted) }
    root.onAppearanceChange = { [weak self] in self?.applyStyle() }
    inputArea.string = input.text ?? ""
    renderNow()
    isReady = true
  }

  func update(input: ToolInput) {
    guard !isTornDown else { return }
    inputArea.string = input.text ?? ""
    renderNow()
  }

  func teardown() {
    isTornDown = true
    generation += 1
    renderTask?.cancel()
    debounceTask?.cancel()
    renderTask = nil
    debounceTask = nil
    segments.onChange = nil
    inputArea.onChange = nil
    treeView.onShowSource = nil
    root.onAppearanceChange = nil
  }

  /// 切换结果视图。
  private func select(_ mode: Mode) {
    guard !isTornDown else { return }
    self.mode = mode
    segments.selectedSegment = mode.rawValue
    show()
  }

  /// 编辑输入区：去抖后再解析。
  private func scheduleRender() {
    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.editDebounce)
      } catch {
        return  // 又有新的编辑或工具已关闭，这次不解析。
      }
      self?.renderNow()
    }
  }

  /// 立即在后台解析当前输入；旧的解析任务取消，迟到的结果按代次丢弃。
  private func renderNow() {
    guard !isTornDown else { return }
    debounceTask?.cancel()
    debounceTask = nil
    renderTask?.cancel()
    generation += 1
    let current = generation
    let text = inputArea.string
    rendered = nil
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      renderTask = nil
      show()
      return
    }
    show()
    renderTask = Task { [weak self] in
      guard let result = await BuiltinJSONRender.render(text) else { return }
      self?.apply(result, generation: current)
    }
  }

  /// 解析结果回到主线程：喂给树视图（它会按位置保住展开状态），再刷新当前视图。
  private func apply(_ result: BuiltinJSONRender, generation: Int) {
    guard generation == self.generation, !isTornDown else { return }
    renderTask = nil
    rendered = result
    treeView.update(result: result.tree)
    show()
  }

  /// 按模式与解析状态决定显示什么：树视图自带错误页；文本视图出错时显示原文并在提示行给出行列。
  private func show() {
    let hasText = !inputArea.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    treeView.isHidden = !(hasText && mode == .tree && rendered != nil)
    outputArea.isHidden = !(hasText && mode != .tree)
    var message: String?
    var isError = false
    if !hasText {
      message = L("在上面粘贴 JSON 文本")
    } else if let rendered {
      if case .failure(let error) = rendered.tree, mode != .tree {
        message = error.localizedSummary
        isError = true
      }
      if mode != .tree {
        outputArea.string = (mode == .minified ? rendered.minified : rendered.formatted) ?? inputArea.string
      }
    } else {
      message = L("正在解析…")
      if mode != .tree { outputArea.string = "" }
    }
    BuiltinToolLayout.setHint(hint, message, isError: isError)
    notifyResultIfChanged()
  }

  /// 外观变化：树与输出文本跟随新的终端主题与字体。
  private func applyStyle() {
    guard !isTornDown else { return }
    let style = actions.terminalStyle()
    treeView.apply(theme: style.theme, font: style.font)
    treeView.appearance = Self.treeAppearance(for: style.theme)
    outputArea.setFont(style.font)
  }

  /// 树视图的明暗跟它的终端主题走，不跟工具面板。树按终端主题自绘底色，标题与「全部展开 / 全部折叠」
  /// 却是系统控件；浅色界面配深色终端主题（或反过来）时，按面板明暗解析的文字会和底色撞色。
  private static func treeAppearance(for theme: TerminalTheme) -> NSAppearance? {
    NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
  }

  /// 「复制」按钮：复制当前视图对应的结果（树视图下为格式化文本）。
  private func copyResult() {
    guard let primaryResultText else { return }
    actions.copy(primaryResultText)
  }

  /// 主结果变了才通知会话。
  private func notifyResultIfChanged() {
    let current = primaryResultText
    guard current != lastPrimary else { return }
    lastPrimary = current
    if isReady { actions.resultDidChange() }
  }
}
