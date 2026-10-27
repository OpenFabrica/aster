// Open Quickly「工具」页（启动器 A）的数据与动作：按查询向工具中心取「识别到」与搜索结果，
// 接上复制结果、预填到终端、在工具面板打开与开成 Pane。哪些过滤器出工具行、插在哪里是
// `OpenQuicklyToolCatalog` 里的纯规则；浮层只把条目转成自己的行。
import AppKit
import AsterCore
import Combine

/// 一行工具目标。字段与浮层内部的 Target 一一对应，由浮层负责转换。
struct OpenQuicklyToolEntry {
  let item: OpenQuicklyItem
  let symbol: String
  let badge: String
  /// 「识别到」行用 accent 图标突出。
  let accented: Bool
  let actionTitle: String
  let action: () -> Void
  var menuActions: [(title: String, handler: () -> Void)] = []
}

/// 工具行的纯规则。
enum OpenQuicklyToolCatalog {
  /// 一次最多列出的搜索行与「识别到」行。
  struct Limits: Equatable {
    var search: Int
    var recognized: Int
  }

  /// 当前过滤器与查询下是否列工具、各列几行；nil 表示不列。
  ///
  /// 「工具」页：空查询按最近常用列出全部功能，有查询列关键词命中与「识别到」。
  /// 「全部」：空查询不列工具——每个功能一行，十几行工具会把标签、文件夹这些「去哪儿」的结果
  /// 挤出首屏；有查询时才列少量命中与「识别到」。其它过滤器不列。
  static func limits(filter: OpenQuicklyFilter, query: String) -> Limits? {
    let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch filter {
    case .tool: return Limits(search: 100, recognized: hasQuery ? 5 : 0)
    case .all: return hasQuery ? Limits(search: 5, recognized: 3) : nil
    default: return nil
    }
  }

  /// 把工具行插到工具小节。浮层结果已按小节优先级排好（智能体 → 工具 → 文件），插入点就是第一个
  /// 文件条目，没有文件时放在末尾。同 id 的旧条目先去掉，避免同一行出现两次。
  static func inserting(_ toolItems: [OpenQuicklyItem], into items: [OpenQuicklyItem]) -> [OpenQuicklyItem] {
    guard !toolItems.isEmpty else { return items }
    let toolIDs = Set(toolItems.map(\.id))
    var result = items.filter { !toolIDs.contains($0.id) }
    let index = result.firstIndex { $0.kind == .file } ?? result.endIndex
    result.insert(contentsOf: toolItems, at: index)
    return result
  }
}

/// 工具行的数据源与动作。每个浮层一个实例。
@MainActor
final class OpenQuicklyToolTargets {
  private let model: AppModel
  private var changesSubscription: AnyCancellable?

  /// - Parameter onChange: 插件列表、启用状态或授权变化后通知浮层刷新可见结果。
  init(model: AppModel, onChange: @escaping () -> Void) {
    self.model = model
    // 工具中心可能在后台扫描完成后发出变化，回到主队列再碰浮层。
    changesSubscription = ToolCenter.shared.changes
      .receive(on: DispatchQueue.main)
      .sink { _ in onChange() }
  }

  /// 当前查询与过滤器下的工具行，顺序见 `ToolLauncherResults.rows`。每次 reload 现算，不进浮层的内存索引：
  /// 关键词、拼音与使用频次排序都由工具中心负责，和工具面板的结果保持一致。
  func entries(query: String, filter: OpenQuicklyFilter) -> [OpenQuicklyToolEntry] {
    guard let limits = OpenQuicklyToolCatalog.limits(filter: filter, query: query) else { return [] }
    let center = ToolCenter.shared
    let context = model.toolContext(for: model.toolTerminalOrigin())
    let contentInput =
      limits.recognized > 0
      ? ToolLauncherResults.contentInput(query: query, files: [], context: context) : nil
    let recognized = contentInput.map { center.contentMatches(for: $0, limit: limits.recognized) } ?? []
    let rows = ToolLauncherResults.rows(
      recognized: recognized, searched: center.search(query, limit: limits.search)
    ) { match in
      contentInput.flatMap { center.inlineResult(for: match.entry, input: $0) }
    }
    return rows.map { entry(for: $0, contentInput: contentInput, context: context) }
  }

  /// 把一行接上动作。主动作：有行内结果就复制，否则在工具面板打开。
  private func entry(
    for row: ToolLauncherRow,
    contentInput: ToolInput?,
    context: ToolContext
  ) -> OpenQuicklyToolEntry {
    let item = OpenQuicklyItem(id: row.id, kind: .tool, title: row.title, detail: row.detail)
    let input = ToolLauncherResults.launchInput(
      for: row, contentInput: contentInput, files: [], context: context)
    let entryID = row.entry.id
    let openInLauncher: () -> Void = { [weak self] in self?.openInLauncher(entry: row.entry, input: input) }
    let openAsPane: () -> Void = { [weak self] in self?.openAsPane(entryID: entryID, input: input) }
    var menu: [(title: String, handler: () -> Void)] = []
    var entry: OpenQuicklyToolEntry
    if let result = row.inlineResult {
      entry = OpenQuicklyToolEntry(
        item: item, symbol: row.symbol, badge: row.badge, accented: true,
        actionTitle: L("复制结果")
      ) { [weak self] in self?.copy(result, entryID: entryID) }
      menu.append((L("预填到终端"), { [weak self] in self?.prefill(result, entryID: entryID) }))
      menu.append((L("在工具面板打开"), openInLauncher))
    } else {
      entry = OpenQuicklyToolEntry(
        item: item, symbol: row.symbol, badge: row.badge, accented: row.origin == .recognized,
        actionTitle: L("在工具面板打开"), action: openInLauncher)
    }
    menu.append((L("开成 Pane"), openAsPane))
    entry.menuActions = menu
    return entry
  }

  // MARK: - 动作

  /// 收起 Open Quickly 浮层。
  private func dismiss() { model.isOpenQuicklyPresented = false }

  /// 复制行内结果并提示。
  private func copy(_ result: String, entryID: String) {
    dismiss()
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(result, forType: .string)
    ToolCenter.shared.recordUse(entryID: entryID)
    model.notice = L("已复制结果")
  }

  /// 预填到当前活动终端（不回车）。浮层关闭后焦点要等下一轮主队列才回到终端，延后写入，
  /// 粘贴保护等界面才会挂在正确的视图上。
  private func prefill(_ result: String, entryID: String) {
    dismiss()
    guard let origin = model.toolTerminalOrigin() else {
      model.notice = L("当前 Pane 不是终端，无法预填")
      return
    }
    ToolCenter.shared.recordUse(entryID: entryID)
    DispatchQueue.main.async { [weak model] in
      if let failure = origin.insert(result) { model?.notice = failure }
    }
  }

  /// 在工具面板里打开：经通知交给 AppDelegate，浮层不依赖面板控制器。
  private func openInLauncher(entry: ToolCatalogEntry, input: ToolInput) {
    dismiss()
    let request = ToolLaunchRequest(entry: entry, input: input, origin: model.toolTerminalOrigin())
    NotificationCenter.default.post(
      name: .asterShowToolLauncher, object: ToolLauncherRequestBox(request: request))
  }

  /// 开成当前标签里的 Pane。
  private func openAsPane(entryID: String, input: ToolInput) {
    dismiss()
    model.openToolPane(entryID: entryID, input: input, origin: model.toolTerminalOrigin())
  }
}
