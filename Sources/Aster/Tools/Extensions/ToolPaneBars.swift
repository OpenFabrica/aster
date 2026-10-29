// `pane.bottom` 与 `pane.header` 的每 Pane 状态：长期持有的底部条与顶条图标组、该 Pane 自己的上下文与分支监听
// （两种视图共用一份）。WorkspaceExtensionHost 拥有一份，调度仍交给窗口共用的 ToolBarScheduler（并发上限跨 Pane 共享）。
// 只给终端 Pane 建，Pane 关闭时释放。
import AppKit
import AsterCore

/// pane 范围视图（pane.bottom 条、pane.header 图标组）的集合。只在主线程使用。
@MainActor
final class ToolPaneBars {
  /// 某个 Pane 的分支变了（参数是 Pane id）。
  var onBranchChange: ((UUID) -> Void)?

  /// 建过视图的 Pane，按第一次挂载的顺序；调度 spec 按它排，结果稳定。
  private(set) var paneIDs: [UUID] = []
  private var bars: [UUID: ToolBarView] = [:]
  private var headers: [UUID: ToolPaneHeaderView] = [:]
  private(set) var contexts: [UUID: ToolBarContext] = [:]
  private var watchers: [UUID: ToolBranchWatcher] = [:]
  private let makeBar: (UUID) -> ToolBarView
  private let makeHeader: (UUID) -> ToolPaneHeaderView

  /// `makeBar` / `makeHeader` 建一个接好回调的底部条 / 顶条图标组（参数是 Pane id）。
  init(makeBar: @escaping (UUID) -> ToolBarView, makeHeader: @escaping (UUID) -> ToolPaneHeaderView) {
    self.makeBar = makeBar
    self.makeHeader = makeHeader
  }

  /// 这个 Pane 已登记（建过任一种视图，有上下文与分支监听）。
  func contains(_ paneID: UUID) -> Bool { watchers[paneID] != nil }

  /// 已建好的底部条（测试与渲染用）。
  func existingBar(for paneID: UUID) -> ToolBarView? { bars[paneID] }

  /// 已建好的顶条图标组（测试与渲染用）。
  func existingHeader(for paneID: UUID) -> ToolPaneHeaderView? { headers[paneID] }

  /// 取（或建）一个 Pane 的底部条；第二个返回值表示这次新建了视图。
  func bar(for paneID: UUID) -> (bar: ToolBarView, isNew: Bool) {
    if let bar = bars[paneID] { return (bar, false) }
    register(paneID)
    let bar = makeBar(paneID)
    bars[paneID] = bar
    return (bar, true)
  }

  /// 取（或建）一个 Pane 的顶条图标组；第二个返回值表示这次新建了视图。
  func header(for paneID: UUID) -> (header: ToolPaneHeaderView, isNew: Bool) {
    if let header = headers[paneID] { return (header, false) }
    register(paneID)
    let header = makeHeader(paneID)
    headers[paneID] = header
    return (header, true)
  }

  /// 第一次给这个 Pane 建视图时登记：排进 `paneIDs`，开分支监听。两种视图共用。
  private func register(_ paneID: UUID) {
    guard watchers[paneID] == nil else { return }
    paneIDs.append(paneID)
    let watcher = ToolBranchWatcher()
    watcher.onBranchChange = { [weak self] in self?.onBranchChange?(paneID) }
    watchers[paneID] = watcher
  }

  /// 只释放全部底部条（pane.bottom 视图都没了，pane.header 还在）：Pane 的登记与上下文保留。
  func removeBars() {
    bars.values.forEach { $0.removeFromSuperview() }
    bars.removeAll()
  }

  /// 只释放全部顶条图标组（pane.header 视图都没了，pane.bottom 还在）。
  func removeHeaders() {
    headers.values.forEach { $0.removeFromSuperview() }
    headers.removeAll()
  }

  /// 按模型重算一个 Pane 的上下文；变了返回新值，没变或 Pane 已不是终端返回 nil。
  func updateContext(for paneID: UUID, model: AppModel) -> ToolBarContext? {
    guard contains(paneID), var next = Self.context(for: paneID, model: model) else { return nil }
    let watcher = watchers[paneID]
    watcher?.watch(directory: next.workingDirectory)
    next.branch = watcher?.branch(for: next.workingDirectory)
    guard next != contexts[paneID] else { return nil }
    contexts[paneID] = next
    return next
  }

  /// 释放已经不存在（或不再是终端）的 Pane：条从视图树摘下、分支监听停止。返回释放了哪些。
  @discardableResult
  func prune(keeping alive: Set<UUID>) -> [UUID] {
    let removed = paneIDs.filter { !alive.contains($0) }
    removed.forEach(remove)
    return removed
  }

  /// 释放全部（视图都没了，或窗口关闭）。
  func removeAll() {
    paneIDs.forEach(remove)
  }

  /// 有视图挂在 `window` 里的 Pane（底部条或顶条图标组；顶条淡出时仍算挂着）。
  func mountedPaneIDs(in window: NSWindow) -> Set<UUID> {
    Set(bars.filter { $0.value.window === window }.map(\.key))
      .union(headers.filter { $0.value.window === window }.map(\.key))
  }

  /// 每个视图都重新解析配色。
  func refreshAppearance() {
    bars.values.forEach { $0.refreshAppearance() }
    headers.values.forEach { $0.refreshAppearance() }
  }

  /// 释放一个 Pane。
  private func remove(_ paneID: UUID) {
    bars.removeValue(forKey: paneID)?.removeFromSuperview()
    headers.removeValue(forKey: paneID)?.removeFromSuperview()
    watchers.removeValue(forKey: paneID)?.stop()
    contexts[paneID] = nil
    paneIDs.removeAll { $0 == paneID }
  }

  // MARK: - 上下文

  /// 终端 Pane（不是工具、文件 Pane）所在的标签。
  static func terminalTab(of paneID: UUID, model: AppModel) -> TerminalTabItem? {
    model.tabs.first {
      $0.layout.descriptor(forPane: paneID)?.kind == .terminal && $0.runtime(for: paneID)?.terminalSession != nil
    }
  }

  /// 该 Pane 自己的上下文（不是活动 Pane）：本机终端才有工作目录，远端为 nil 并标 `isRemote`；
  /// `paneID` 恒为它自己，所以活动 Pane 切换不会让 pane 视图重跑。分支由调用方补。
  static func context(for paneID: UUID, model: AppModel) -> ToolBarContext? {
    guard let tab = terminalTab(of: paneID, model: model), let session = tab.runtime(for: paneID)?.terminalSession
    else { return nil }
    let tool = model.toolContext(for: ToolTerminalOrigin(session: session, paneID: paneID))
    let agent = session.activeAgentProvider.map {
      ToolBarAgentContext(
        provider: $0.rawValue, state: session.agentTaskState.rawValue, sessionID: session.activeAgentSessionID)
    }
    return ToolBarContext(
      workingDirectory: tool.workingDirectory, isRemote: tool.isRemote, locale: tool.locale,
      appearance: tool.appearance, tabID: tab.id.uuidString, paneID: paneID.uuidString, agent: agent)
  }

  /// 往这个 Pane 写终端的目标（条上 `terminal` 动作写到条所在的 Pane）。
  static func terminal(of paneID: UUID, model: AppModel) -> ToolTerminalOrigin? {
    guard let session = terminalTab(of: paneID, model: model)?.runtime(for: paneID)?.terminalSession else {
      return nil
    }
    return ToolTerminalOrigin(session: session, paneID: paneID)
  }
}
