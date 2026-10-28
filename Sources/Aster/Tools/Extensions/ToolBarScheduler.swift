// 每个工作区窗口一份的 bar 调度器：持有各视图的 ToolBarFeed，负责去抖、并发上限、定时自续与窗口可见性。
// 遵守 docs/developer/energy-efficiency.md：窗口不可见时不跑脚本、不留定时，只记 stale；定时用单次 sleep 自续，不用常驻 Timer。
import AsterCore
import Foundation

/// 调度器用的时钟。测试注入手动时钟，不真等 30 s。
struct ToolBarSchedulerClock {
  var now: @MainActor () -> Date
  /// 睡 `seconds` 秒；所在 Task 取消时抛错。
  var sleep: @MainActor (_ seconds: TimeInterval) async throws -> Void

  /// 墙钟 + `Task.sleep`。
  static var live: ToolBarSchedulerClock {
    ToolBarSchedulerClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
  }
}

/// 调度器里的一份 feed：哪个视图、调度键、属于哪个 Pane（`pane.bottom`）以及它的初始上下文。
struct ToolBarFeedSpec {
  let key: String
  let entry: ToolViewEntry
  /// `pane.bottom` 的 Pane；窗口 / 标签范围的视图为 nil，共用调度器的 `context`。
  let paneID: UUID?
  /// pane 范围的上下文（该 Pane 自己的 cwd 等）；标签范围忽略，用调度器的 `context`。
  let context: ToolBarContext?
}

/// bar 调度器。只在主线程使用。
@MainActor
final class ToolBarScheduler {
  /// 每窗口同时运行的脚本上限。
  static let windowConcurrency = 4
  /// 每个插件同时运行的脚本上限。
  static let pluginConcurrency = 2

  /// 某个视图的显示或运行状态变了（参数是 feed 键：标签范围是 `ToolViewEntry.id`）。
  var onFeedChange: ((String) -> Void)?

  /// `pane.bottom` 一份 feed 的键：同一视图在每个 Pane 各一份，缓存与失败计数互不影响。
  static func paneFeedKey(entryID: String, paneID: UUID) -> String {
    "\(entryID)@\(paneID.uuidString)"
  }

  /// 窗口可见（未遮挡、未最小化、bar 在视图树里）。变为 false 时取消定时与排队，触发只记 stale；
  /// 变回 true 时 stale 与已到点的视图立即跑。
  var isVisible: Bool {
    didSet {
      guard isVisible != oldValue, !isTornDown else { return }
      isVisible ? resume(order.filter(isActive)) : pause(order)
    }
  }

  /// 能跑脚本的 Pane（窗口里选中标签的、挂着条的终端 Pane）。不在里面的 pane feed 与窗口不可见时一样：
  /// 不跑、不留定时，触发只记 stale，回到这里时补跑。
  private(set) var visiblePaneIDs: Set<UUID> = []
  /// pane feed 的键 → Pane。
  private var feedPanes: [String: UUID] = [:]

  private(set) var context: ToolBarContext
  private var feeds: [String: ToolBarFeed] = [:]
  /// 目录顺序；补跑、恢复可见时按它遍历，结果稳定。
  private var order: [String] = []
  /// 去抖中的触发与等着的那一次 sleep。
  private var debounced: [String: ToolBarTrigger] = [:]
  private var debounceTask: Task<Void, Never>?
  /// 并发已满时排队的视图与触发。
  private var queue: [String] = []
  private var queuedTriggers: [String: ToolBarTrigger] = [:]
  /// 正在运行的视图 → 插件 id（并发计数）。
  private var running: [String: String] = [:]
  /// 每个视图下一次定时到点的时刻与触发；不可见时保留，恢复可见时据此判断是否已过期。
  private var dueDates: [String: (date: Date, trigger: ToolBarTrigger)] = [:]
  private var timers: [String: Task<Void, Never>] = [:]
  private var isTornDown = false
  private let runner: ToolBarRunner
  private let clock: ToolBarSchedulerClock

  init(
    context: ToolBarContext = ToolBarContext(),
    isVisible: Bool = false,
    runner: @escaping ToolBarRunner,
    clock: ToolBarSchedulerClock = .live
  ) {
    self.context = context
    self.isVisible = isVisible
    self.runner = runner
    self.clock = clock
  }

  /// 按 feed 键取 feed。
  func feed(id: String) -> ToolBarFeed? { feeds[id] }

  /// 这份 feed 现在能不能跑：窗口可见，且 pane feed 的 Pane 在 `visiblePaneIDs` 里。
  private func isActive(_ id: String) -> Bool {
    guard isVisible else { return false }
    guard let paneID = feedPanes[id] else { return true }
    return visiblePaneIDs.contains(paneID)
  }

  /// 正在运行的脚本个数（测试用）。
  var runningCount: Int { running.count }

  // MARK: - 目录

  /// 只有窗口 / 标签范围视图时的简写：键是 `entry.id`，上下文共用 `context`。
  func update(entries: [ToolViewEntry]) {
    update(specs: entries.map { ToolBarFeedSpec(key: $0.id, entry: $0, paneID: nil, context: nil) })
  }

  /// 对齐全部 feed（标签范围与 pane 范围一起给，没列出的视为已移除）：新 feed 跑一次 `initial`；没了的取消运行与定时；
  /// 视图声明或插件目录变了按新视图重建。状态或权限变化（例如刚授权）以及开发目录插件的任何变化（文件被改，
  /// 工具中心重新扫描）都按 `manual` 重跑一次。pane feed 顺带换上 spec 里的上下文。
  func update(specs: [ToolBarFeedSpec]) {
    guard !isTornDown else { return }
    let ids = specs.map(\.key)
    for id in order where !ids.contains(id) { remove(id) }
    for spec in specs {
      let id = spec.key
      let entry = spec.entry
      if let feed = feeds[id], feed.entry.contribution == entry.contribution,
        feed.entry.pluginDirectory == entry.pluginDirectory
      {
        let previous = feed.entry
        if previous != entry || entry.source == .development {
          feed.update(entry: entry)
          if case .needsApproval = entry.status {
            cancelScheduling(id)
          } else if previous.status != entry.status || previous.permissions != entry.permissions
            || entry.source == .development
          {
            request(id, .manual, debounced: true)
          }
        }
        if spec.paneID != nil, let context = spec.context { apply(context, to: feed) }
      } else {
        if feeds[id] != nil { remove(id) }
        let feed = ToolBarFeed(
          key: id, entry: entry, context: spec.paneID == nil ? context : (spec.context ?? context), runner: runner,
          now: clock.now)
        feed.onChange = { [weak self] in self?.onFeedChange?(id) }
        feeds[id] = feed
        feedPanes[id] = spec.paneID
        request(id, .initial, debounced: true)
      }
    }
    order = ids
  }

  /// 去掉一个视图：取消运行（结束进程组）、定时与排队，并让出并发名额。
  private func remove(_ id: String) {
    feeds.removeValue(forKey: id)?.cancel()
    feedPanes[id] = nil
    cancelScheduling(id)
    drainQueue()
  }

  /// 清掉一个视图的定时、去抖、排队与并发记录（不动 feed 本身的运行）。
  private func cancelScheduling(_ id: String) {
    timers.removeValue(forKey: id)?.cancel()
    dueDates[id] = nil
    debounced[id] = nil
    queuedTriggers[id] = nil
    queue.removeAll { $0 == id }
    if running.removeValue(forKey: id) != nil { feeds[id]?.cancel() }
  }

  // MARK: - 触发

  /// 换标签范围的上下文：每个 feed 自己判断关心的字段变没变（命中缓存直接显示），需要跑的去抖后再跑。
  /// pane feed 不受影响，它们只认自己 Pane 的上下文。
  func updateContext(_ newContext: ToolBarContext) {
    guard !isTornDown, newContext != context else { return }
    context = newContext
    for id in order where feedPanes[id] == nil {
      if let feed = feeds[id] { apply(newContext, to: feed) }
    }
  }

  /// 换某个 Pane 的上下文（它自己的 cwd、远端状态、Agent），只影响这个 Pane 的 feed。
  func updatePaneContext(_ newContext: ToolBarContext, paneID: UUID) {
    guard !isTornDown else { return }
    for id in order where feedPanes[id] == paneID {
      if let feed = feeds[id] { apply(newContext, to: feed) }
    }
  }

  /// 把上下文交给一份 feed：要跑就去抖后提交；命中缓存换了显示内容时定时按新显示的结果重新起算。
  private func apply(_ newContext: ToolBarContext, to feed: ToolBarFeed) {
    guard newContext != feed.context else { return }
    if let trigger = feed.setContext(newContext) {
      request(feed.key, trigger, debounced: true)
    } else if !feed.isRunning {
      scheduleNextRun(for: feed)
    }
  }

  /// 换能跑脚本的 Pane 集合：离开的 Pane 暂停（定时取消、排队与去抖转 stale），回来的 Pane 补跑 stale 或已到点的定时。
  func setVisiblePanes(_ paneIDs: Set<UUID>) {
    guard !isTornDown, paneIDs != visiblePaneIDs else { return }
    let previous = visiblePaneIDs
    visiblePaneIDs = paneIDs
    guard isVisible else { return }
    let left = previous.subtracting(paneIDs)
    let joined = paneIDs.subtracting(previous)
    pause(order.filter { feedPanes[$0].map(left.contains) ?? false })
    resume(order.filter { feedPanes[$0].map(joined.contains) ?? false })
  }

  /// 用户点了刷新或重跑：不去抖，立即提交（运行中则合并成一次补跑）。
  func refresh(entryID: String) {
    request(entryID, .manual, debounced: false)
  }

  /// 收下一个触发：不可见只记 stale；否则去抖或直接提交。
  private func request(_ id: String, _ trigger: ToolBarTrigger, debounced shouldDebounce: Bool) {
    guard !isTornDown, let feed = feeds[id] else { return }
    guard isActive(id) else {
      feed.staleTrigger = ToolBarFeed.merge(feed.staleTrigger, trigger)
      return
    }
    guard shouldDebounce else {
      submit(id, trigger)
      return
    }
    debounced[id] = ToolBarFeed.merge(debounced[id], trigger)
    // 每来一个触发都重新起算 300 ms：连续 `cd`、切标签时只在安静下来后跑一次。
    debounceTask?.cancel()
    let sleep = clock.sleep
    debounceTask = Task { [weak self] in
      do { try await sleep(ToolBarProtocol.debounce) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.debounceTask = nil
      self.flushDebounced()
    }
  }

  /// 去抖结束：按目录顺序提交攒下的触发。
  private func flushDebounced() {
    let pending = debounced
    debounced = [:]
    for id in order {
      guard let trigger = pending[id] else { continue }
      submit(id, trigger)
    }
  }

  /// 提交一次运行：去抖期间上下文可能又变回有新鲜缓存的那个，这时上下文触发作废；运行中合并成补跑；
  /// 未到最短间隔改成到点的定时；并发满了排队。
  private func submit(_ id: String, _ trigger: ToolBarTrigger) {
    guard !isTornDown, let feed = feeds[id] else { return }
    guard isActive(id) else {
      feed.staleTrigger = ToolBarFeed.merge(feed.staleTrigger, trigger)
      return
    }
    if Self.isContextTrigger(trigger), feed.hasFreshResultForCurrentContext {
      scheduleNextRun(for: feed)
      return
    }
    if feed.isRunning {
      feed.pendingTrigger = ToolBarFeed.merge(feed.pendingTrigger, trigger)
      return
    }
    if let earliest = feed.earliestRunDate(for: trigger) {
      schedule(id, at: earliest, trigger: trigger)
      return
    }
    guard canStart(feed) else {
      queuedTriggers[id] = ToolBarFeed.merge(queuedTriggers[id], trigger)
      if !queue.contains(id) { queue.append(id) }
      return
    }
    timers.removeValue(forKey: id)?.cancel()
    dueDates[id] = nil
    running[id] = feed.entry.pluginID
    let started = feed.start(trigger: trigger) { [weak self] finished in self?.didFinish(finished) }
    if !started { running[id] = nil }
  }

  /// 上下文类触发：上下文已有新鲜结果时可以丢掉。
  private static func isContextTrigger(_ trigger: ToolBarTrigger) -> Bool {
    switch trigger {
    case .cwd, .branch, .activePane, .agent: true
    case .initial, .interval, .manual: false
    }
  }

  /// 并发上限：每窗口 4、每插件 2。
  private func canStart(_ feed: ToolBarFeed) -> Bool {
    guard running.count < Self.windowConcurrency else { return false }
    return running.values.filter { $0 == feed.entry.pluginID }.count < Self.pluginConcurrency
  }

  /// 一次运行结束：让出名额，排好下一次定时，再处理运行中攒下的补跑与排队。
  private func didFinish(_ feed: ToolBarFeed) {
    let id = feed.key
    guard !isTornDown, feeds[id] === feed else { return }
    running[id] = nil
    scheduleNextRun(for: feed)
    if let pending = feed.pendingTrigger {
      feed.pendingTrigger = nil
      submit(id, pending)
    }
    drainQueue()
  }

  /// 有空名额就按排队顺序提交。
  private func drainQueue() {
    guard isVisible, !isTornDown else { return }
    for id in queue {
      guard isActive(id), let feed = feeds[id], canStart(feed) else { continue }
      queue.removeAll { $0 == id }
      if let trigger = queuedTriggers.removeValue(forKey: id) { submit(id, trigger) }
    }
  }

  // MARK: - 定时

  /// 按 feed 当前结果排下一次 `interval` 运行；不定时的视图清掉旧定时。
  private func scheduleNextRun(for feed: ToolBarFeed) {
    let id = feed.key
    guard let date = feed.nextRunDate() else {
      timers.removeValue(forKey: id)?.cancel()
      dueDates[id] = nil
      return
    }
    schedule(id, at: date, trigger: .interval)
  }

  /// 记下到点时刻；可见时起一次单次 sleep，到点后提交。替换该视图原有的定时。
  private func schedule(_ id: String, at date: Date, trigger: ToolBarTrigger) {
    dueDates[id] = (date, trigger)
    timers.removeValue(forKey: id)?.cancel()
    guard isActive(id) else { return }
    let delay = max(0, date.timeIntervalSince(clock.now()))
    let sleep = clock.sleep
    timers[id] = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.timers[id] = nil
      self.dueDates[id] = nil
      self.submit(id, trigger)
    }
  }

  // MARK: - 可见性

  /// 暂停一批 feed（窗口不可见，或 Pane 离开了选中标签）：取消定时（保留到点时刻），排队和去抖中的触发转成 stale。
  /// 正在跑的脚本跑完为止。
  private func pause(_ ids: [String]) {
    for id in ids {
      guard let feed = feeds[id] else { continue }
      if let trigger = debounced.removeValue(forKey: id) {
        feed.staleTrigger = ToolBarFeed.merge(feed.staleTrigger, trigger)
      }
      if let trigger = queuedTriggers.removeValue(forKey: id) {
        feed.staleTrigger = ToolBarFeed.merge(feed.staleTrigger, trigger)
      }
      queue.removeAll { $0 == id }
      timers.removeValue(forKey: id)?.cancel()
    }
    if debounced.isEmpty {
      debounceTask?.cancel()
      debounceTask = nil
    }
  }

  /// 恢复一批 feed：stale 的立即跑；定时已过期的也立即跑；没到点的重新起 sleep。
  private func resume(_ ids: [String]) {
    let now = clock.now()
    for id in ids {
      guard let feed = feeds[id] else { continue }
      if let stale = feed.staleTrigger {
        feed.staleTrigger = nil
        submit(id, stale)
      } else if let due = dueDates[id] {
        if due.date <= now {
          dueDates[id] = nil
          submit(id, due.trigger)
        } else {
          schedule(id, at: due.date, trigger: due.trigger)
        }
      }
    }
  }

  // MARK: - 收尾

  /// 窗口关闭：取消一切，包括正在运行的脚本（运行器在 Task 取消时结束进程组）。之后不再接受任何调用。
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    debounceTask?.cancel()
    debounceTask = nil
    timers.values.forEach { $0.cancel() }
    timers = [:]
    feeds.values.forEach { $0.cancel() }
    feeds = [:]
    feedPanes = [:]
    order = []
    running = [:]
    queue = []
    queuedTriggers = [:]
    debounced = [:]
    dueDates = [:]
  }
}
