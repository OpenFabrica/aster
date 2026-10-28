// 每个工作区窗口的插件 panel 会话缓存：按视图 id 长期持有 ToolSessionViewController，
// 工作区整树重建、详情面板重建时只借用，不重新加载网页。上下文变化推 `context` 事件，不重新进入。
import AppKit
import AsterCore
import Foundation

/// panel 会话缓存。
@MainActor
final class ToolPanelSessionCache {
  /// 一个 panel 视图的会话与宿主。会话对宿主是弱引用，宿主由缓存持有。
  private struct Record {
    let session: ToolSessionViewController
    let host: ToolPanelSessionHost
    /// 创建时的视图声明与位置；清单或位置变了就重建，页面入口才会跟着换。
    let contribution: ToolViewContribution
    let slot: ToolViewSlot
  }

  private weak var model: AppModel?
  private let center: ToolCenter
  private var records: [String: Record] = [:]
  /// 最近一次交给会话的上下文；相同的上下文不重复推送。
  private var context: ToolBarContext?
  /// 最近一次 `reconcile` 收到的目录；延后核对时以它为准。
  private var latestEntries: [ToolViewEntry] = []
  private var reconcileScheduled = false
  private var isTornDown = false

  init(model: AppModel, center: ToolCenter = .shared) {
    self.model = model
    self.center = center
  }

  /// 窗口释放时兜底停掉全部会话。
  isolated deinit {
    for record in records.values { record.session.teardown() }
  }

  /// 当前缓存着会话的视图 id（测试用）。
  var cachedEntryIDs: Set<String> { Set(records.keys) }

  /// 借出视图的会话：第一次按 `context` 创建，之后复用。不可挂载、不是 panel 或窗口已关闭时为 nil。
  func session(for entry: ToolViewEntry, context: ToolBarContext) -> ToolSessionViewController? {
    guard !isTornDown else { return nil }
    if let record = records[entry.id] {
      updateContext(context)
      return record.session
    }
    guard let model, entry.isMountable, entry.contribution.kind == .panel else { return nil }
    // 先对齐已有会话，再按同一份上下文建新会话：所有会话看到的上下文一致。
    updateContext(context)
    let request = center.viewLaunchRequest(
      for: entry, input: Self.input(for: context), origin: model.toolTerminalOrigin(),
      extendedContext: Self.extendedContext(for: context))
    let host = ToolPanelSessionHost(model: model)
    let session = center.makeSession(for: request, host: host)
    host.session = session
    records[entry.id] = Record(session: session, host: host, contribution: entry.contribution, slot: entry.slot)
    return session
  }

  /// 把新上下文推给所有存活的会话（页面收到 `context` 事件，不重新进入）。上下文没变时什么都不做。
  func updateContext(_ context: ToolBarContext) {
    guard !isTornDown, context != self.context else { return }
    self.context = context
    guard !records.isEmpty else { return }
    let input = Self.input(for: context)
    let extended = Self.extendedContext(for: context)
    let origin = model?.toolTerminalOrigin()
    for record in records.values {
      record.session.updateContext(input: input, origin: origin, extendedContext: extended)
    }
  }

  /// 目录变化后核对：不再存在、不再可挂载、清单声明或位置变了的视图，下一轮主队列 `teardown()`。
  /// 延后一轮的原因：本方法在 `ToolCenter.changes` 的回调里调用，这时工具中心刚通知完各会话、
  /// Inspector 可能还在同一轮通知里摘下页签；同步拆会话会在它们收尾前释放 WebView。
  /// 延后执行时按最近一次收到的目录核对，同一轮里先消失又回来的视图不会被误拆。
  func reconcile(entries: [ToolViewEntry]) {
    guard !isTornDown else { return }
    latestEntries = entries
    guard !reconcileScheduled else { return }
    reconcileScheduled = true
    DispatchQueue.main.async { [weak self] in self?.performReconcile() }
  }

  /// 窗口关闭：结束所有会话。之后不再借出会话。
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    for id in Array(records.keys) { discard(id) }
  }

  // MARK: - 内部

  /// 按最近一次目录释放失效的会话。
  private func performReconcile() {
    reconcileScheduled = false
    guard !isTornDown else { return }
    let entries = Dictionary(latestEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // 遍历的是字典的副本，循环里删除记录是安全的。
    for (id, record) in records {
      let entry = entries[id]
      let stillValid =
        entry.map {
          $0.isMountable && $0.contribution.kind == .panel && $0.contribution == record.contribution
            && $0.slot == record.slot
        } ?? false
      if !stillValid { discard(id) }
    }
  }

  /// 释放一个会话：先 `teardown()` 停掉 WebView，再把视图摘出视图树。
  private func discard(_ id: String) {
    guard let record = records.removeValue(forKey: id) else { return }
    record.session.teardown()
    record.session.removeFromParent()
    record.session.viewIfLoaded?.removeFromSuperview()
  }

  /// 上下文里 `ToolContext` 的那部分。panel 没有输入文本与文件。
  static func input(for context: ToolBarContext) -> ToolInput {
    ToolInput(
      context: ToolContext(
        workingDirectory: context.workingDirectory, isRemote: context.isRemote, locale: context.locale,
        appearance: context.appearance))
  }

  /// `ToolContext` 之外的扩展上下文；没有值的字段不出现（与 `ToolContext` 编码省略 nil 一致）。
  static func extendedContext(for context: ToolBarContext) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    if let branch = context.branch { result["branch"] = .string(branch) }
    if let tabID = context.tabID { result["tabID"] = .string(tabID) }
    if let paneID = context.paneID { result["paneID"] = .string(paneID) }
    if let agent = context.agent {
      result["agent"] = .object(["provider": .string(agent.provider), "state": .string(agent.state)])
    }
    return result
  }
}
