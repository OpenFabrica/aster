// 界面扩展 bar 的单视图数据源：一个视图在当前上下文下显示什么、要不要跑脚本。按上下文缓存结果、
// 记连续失败与退避；去抖、并发上限、定时与可见性在 ToolBarScheduler。规则见 docs/developer/tools-and-plugins.md「界面扩展」。
import AsterCore
import Foundation

/// 一次 bar 脚本运行的输入。
struct ToolBarRunRequest: Sendable {
  let pluginID: String
  let viewID: String
  let source: ToolViewScriptSource
  let trigger: ToolBarTrigger
  let context: ToolBarContext
}

/// 运行一次 bar 脚本并解析输出。生产实现见 `ToolBarFeed.liveRunner(center:)`，测试注入假实现。
/// 所在 Task 被取消时必须尽快结束（生产实现会结束脚本进程组）。
typealias ToolBarRunner = @MainActor (ToolBarRunRequest) async throws -> ToolBarOutput

/// 运行前发现插件不能运行。
enum ToolBarRunError: Error, Equatable, LocalizedError {
  /// 插件需要（重新）授权：第一次运行、用户插件文件变了或权限变多。
  case needsApproval
  /// 插件不存在、已停用或没有目录。
  case unavailable

  var errorDescription: String? {
    switch self {
    case .needsApproval: L("需要授权")
    case .unavailable: L("插件不可用")
    }
  }
}

/// feed 的显示状态。「正在运行」与它正交（见 `ToolBarFeed.runningSince`）：运行中继续显示上一份结果，
/// 避免每次重跑都让条闪一下、终端高度跟着变。
enum ToolBarFeedState: Equatable {
  /// 还没有任何结果。
  case idle
  case ready(items: [ToolBarItem], at: Date)
  /// 最近一次运行失败；`message` 是给用户看的摘要（stderr 或错误说明）。
  case failed(message: String, at: Date)
  /// 插件需要授权，不跑脚本。
  case needsApproval
}

/// 一个 bar 视图（× 当前上下文）的数据源。只在主线程使用。
@MainActor
final class ToolBarFeed {
  /// 每个视图最多缓存的上下文个数；切回旧标签命中缓存就不重跑。
  static let cacheLimit = 16

  /// 一份成功结果。
  private struct CachedResult {
    let items: [ToolBarItem]
    let at: Date
    let ttl: Int?
  }

  /// 调度与缓存的键：窗口 / 标签范围的视图是 `entry.id`；`pane.bottom` 每个 Pane 一份，见 `ToolBarScheduler.paneFeedKey`。
  let key: String
  private(set) var entry: ToolViewEntry
  /// 最新上下文；运行总用它，结果按运行时的上下文入缓存。
  private(set) var context: ToolBarContext
  private(set) var state: ToolBarFeedState = .idle
  /// 当前运行的开始时间；nil 表示没在运行。视图据此在运行超过 1 s 后才显示 spinner。
  private(set) var runningSince: Date?
  private(set) var consecutiveFailures = 0
  /// 运行中又来的触发；完成后调度器补跑一次（多次合并为一次）。
  var pendingTrigger: ToolBarTrigger?
  /// 窗口不可见期间来的触发；恢复可见时调度器立即补跑。
  var staleTrigger: ToolBarTrigger?
  /// 显示状态或运行状态变化。
  var onChange: (() -> Void)?

  private var cache: [ToolBarContext: CachedResult] = [:]
  /// 缓存键的使用顺序，最近用过的在末尾；超出上限时淘汰最前面的。
  private var cacheOrder: [ToolBarContext] = []
  /// 当前显示结果的 ttl（只对 ready 有意义）。
  private var displayedTTL: Int?
  /// 最近一次开始运行的缓存键与时刻：同一上下文最短间隔的依据。
  private var lastRun: (key: ToolBarContext, at: Date)?
  private var task: Task<Void, Never>?
  /// 每次开始或取消运行加一；迟到的旧结果按它丢弃。
  private var generation = 0
  private let runner: ToolBarRunner
  private let now: () -> Date

  init(
    key: String? = nil,
    entry: ToolViewEntry,
    context: ToolBarContext,
    runner: @escaping ToolBarRunner,
    now: @escaping () -> Date
  ) {
    self.key = key ?? entry.id
    self.entry = entry
    self.context = context
    self.runner = runner
    self.now = now
    if case .needsApproval = entry.status { state = .needsApproval }
  }

  var isRunning: Bool { task != nil }

  // MARK: - 条目与上下文

  /// 换上目录里的新条目（视图声明不变，只是状态或权限变了）。变成需要授权时停掉运行并显示授权提示。
  func update(entry: ToolViewEntry) {
    self.entry = entry
    if case .needsApproval = entry.status {
      cancel()
      setState(.needsApproval)
    } else if state == .needsApproval {
      setState(.idle)
    }
  }

  /// 缓存键：只保留这个视图声明关心的上下文字段（`refresh.on`）。没声明 `cwd` 的视图（例如时钟）
  /// 换目录不算变化；locale / appearance 不进键，它们几乎不变，脚本从 stdin 照样拿得到。
  func cacheKey(for context: ToolBarContext) -> ToolBarContext {
    let triggers = Set(entry.contribution.resolvedRefresh.resolvedTriggers)
    var key = ToolBarContext(locale: "", appearance: "")
    if triggers.contains(.cwd) {
      key.workingDirectory = context.workingDirectory
      key.isRemote = context.isRemote
    }
    if triggers.contains(.branch) { key.branch = context.branch }
    if triggers.contains(.activePane) {
      key.tabID = context.tabID
      key.paneID = context.paneID
    }
    if triggers.contains(.agent) { key.agent = context.agent }
    return key
  }

  /// 换上下文。键没变返回 nil；键变了先显示该键的缓存（哪怕已过期，也比显示别的目录的结果对），
  /// 缓存仍新鲜返回 nil，否则返回应发的触发。没有缓存时继续显示上一份结果：每次 `cd` 都清空
  /// 会让条先消失再出现，终端高度跟着来回变。
  func setContext(_ newContext: ToolBarContext) -> ToolBarTrigger? {
    let oldKey = cacheKey(for: context)
    let newKey = cacheKey(for: newContext)
    context = newContext
    guard oldKey != newKey else { return nil }
    if let cached = cache[newKey] {
      touchCache(newKey)
      displayedTTL = cached.ttl
      if case .needsApproval = state {} else { setState(.ready(items: cached.items, at: cached.at)) }
      if isFresh(cached) { return nil }
    }
    return Self.trigger(from: oldKey, to: newKey)
  }

  /// 当前上下文有没有仍新鲜的缓存结果；调度器在去抖结束时据此丢掉已经不需要的上下文触发。
  var hasFreshResultForCurrentContext: Bool {
    cache[cacheKey(for: context)].map(isFresh) ?? false
  }

  /// 两个键之间最主要的差别对应的触发：目录 > 分支 > 活动 Pane > Agent。
  private static func trigger(from old: ToolBarContext, to new: ToolBarContext) -> ToolBarTrigger {
    if old.workingDirectory != new.workingDirectory || old.isRemote != new.isRemote { return .cwd }
    if old.branch != new.branch { return .branch }
    if old.tabID != new.tabID || old.paneID != new.paneID { return .activePane }
    return .agent
  }

  // MARK: - 节流与定时

  /// 现在能不能为 `trigger` 跑；不能时返回最早可以跑的时刻。
  ///
  /// 同一上下文两次运行至少隔 `ToolBarProtocol.minimumInterval`。例外：`initial`（第一次挂载）与
  /// `manual`（用户点了刷新或重跑，运行中再点只会合并成一次补跑，刷不起来）。上下文触发换了键时
  /// 自然不受限；同键的情况只发生在失败结果（不入缓存）来回切换时，正好挡住失败脚本被反复拉起。
  func earliestRunDate(for trigger: ToolBarTrigger) -> Date? {
    guard trigger != .initial, trigger != .manual, let lastRun, lastRun.key == cacheKey(for: context) else {
      return nil
    }
    let allowed = lastRun.at.addingTimeInterval(ToolBarProtocol.minimumInterval)
    return allowed > now() ? allowed : nil
  }

  /// 下一次定时运行的时刻；nil 表示不定时（`interval == 0` 且没有 ttl、需要授权、还没结果）。
  /// 成功：`ttl ?? interval` 之后。失败：按 `interval` 重试，连续失败达到阈值后退避到
  /// `max(interval × 4, failureBackoffMinimum)`；`interval == 0` 的视图失败后只等用户点重跑或上下文变化。
  func nextRunDate() -> Date? {
    let interval = TimeInterval(entry.contribution.resolvedRefresh.resolvedInterval)
    switch state {
    case .ready(_, let at):
      if let ttl = displayedTTL { return at.addingTimeInterval(TimeInterval(ttl)) }
      return interval > 0 ? at.addingTimeInterval(interval) : nil
    case .failed(_, let at):
      guard interval > 0 else { return nil }
      let delay =
        consecutiveFailures >= ToolBarProtocol.failureBackoffThreshold
        ? max(interval * 4, ToolBarProtocol.failureBackoffMinimum) : interval
      return at.addingTimeInterval(delay)
    case .idle, .needsApproval:
      return nil
    }
  }

  // MARK: - 运行

  /// 开始一次运行。需要授权时不跑（返回 false）；已在运行时记成补跑（返回 false）。
  /// 完成（成功或失败）后回调 `completion`；被 `cancel()` 取消的运行不回调。
  @discardableResult
  func start(trigger: ToolBarTrigger, completion: @escaping @MainActor (ToolBarFeed) -> Void) -> Bool {
    if case .needsApproval = entry.status {
      setState(.needsApproval)
      return false
    }
    guard task == nil else {
      pendingTrigger = Self.merge(pendingTrigger, trigger)
      return false
    }
    generation += 1
    let generation = generation
    let key = cacheKey(for: context)
    let startedAt = now()
    lastRun = (key, startedAt)
    runningSince = startedAt
    let request = ToolBarRunRequest(
      pluginID: entry.pluginID, viewID: entry.contribution.id,
      source: entry.contribution.source ?? ToolViewScriptSource(command: []), trigger: trigger, context: context)
    let runner = runner
    task = Task { [weak self] in
      let result: Result<ToolBarOutput, any Error>
      do {
        result = .success(try await runner(request))
      } catch {
        result = .failure(error)
      }
      guard let self, self.generation == generation else { return }
      self.finish(result, key: key)
      completion(self)
    }
    onChange?()
    return true
  }

  /// 取消正在进行的运行（进程组由运行器结束），丢掉补跑。
  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    pendingTrigger = nil
    if runningSince != nil {
      runningSince = nil
      onChange?()
    }
  }

  /// 收下运行结果：成功入缓存并清零失败计数；只有运行时的上下文仍是当前上下文时才显示，
  /// 否则只入缓存（调度器会按补跑为新上下文再跑）。
  private func finish(_ result: Result<ToolBarOutput, any Error>, key: ToolBarContext) {
    task = nil
    runningSince = nil
    let isCurrent = cacheKey(for: context) == key
    let at = now()
    switch result {
    case .success(let output):
      consecutiveFailures = 0
      store(CachedResult(items: output.items, at: at, ttl: output.ttl), for: key)
      if isCurrent {
        displayedTTL = output.ttl
        state = .ready(items: output.items, at: at)
      }
    case .failure(let error as ToolBarRunError) where error == .needsApproval:
      state = .needsApproval
    case .failure(let error):
      consecutiveFailures += 1
      if isCurrent { state = .failed(message: Self.message(for: error), at: at) }
    }
    onChange?()
  }

  /// 错误给用户看的摘要。
  static func message(for error: any Error) -> String {
    switch error {
    case let error as ScriptToolError: error.localizedMessage
    case let error as LocalizedError: error.errorDescription ?? error.localizedDescription
    default: error.localizedDescription
    }
  }

  /// 合并两个待跑的触发：`manual` 优先（用户点的），其余保留先来的。
  static func merge(_ existing: ToolBarTrigger?, _ incoming: ToolBarTrigger) -> ToolBarTrigger {
    guard let existing, incoming != .manual else { return incoming }
    return existing
  }

  // MARK: - 缓存

  /// 缓存仍新鲜：没有定时（`interval == 0` 且无 ttl）的结果一直有效，直到上下文触发；否则按 `ttl ?? interval`。
  private func isFresh(_ cached: CachedResult) -> Bool {
    let interval = entry.contribution.resolvedRefresh.resolvedInterval
    guard let lifetime = cached.ttl ?? (interval > 0 ? interval : nil) else { return true }
    return now().timeIntervalSince(cached.at) < TimeInterval(lifetime)
  }

  /// 写缓存并按最近使用淘汰。
  private func store(_ result: CachedResult, for key: ToolBarContext) {
    cache[key] = result
    touchCache(key)
    while cacheOrder.count > Self.cacheLimit {
      cache[cacheOrder.removeFirst()] = nil
    }
  }

  /// 把键移到最近使用的位置。
  private func touchCache(_ key: ToolBarContext) {
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
  }

  /// 缓存里的上下文个数（测试用）。
  var cachedContextCount: Int { cache.count }

  /// 改显示状态并通知。
  private func setState(_ newState: ToolBarFeedState) {
    guard state != newState else { return }
    state = newState
    onChange?()
  }
}

// MARK: - 生产运行器

extension ToolBarFeed {
  /// 生产运行器：运行前让工具中心核对插件文件（用户插件文件被原地改过就变成需要授权），
  /// 再在后台组装、运行脚本并按 bar 协议解析 stdout。
  static func liveRunner(center: ToolCenter = .shared) -> ToolBarRunner {
    { [weak center] request in
      guard let center else { throw ToolBarRunError.unavailable }
      let status = await center.prepareToRun(pluginID: request.pluginID)
      if case .needsApproval? = status { throw ToolBarRunError.needsApproval }
      guard status == .ready, let plugin = center.runtimeInfo(pluginID: request.pluginID) else {
        throw ToolBarRunError.unavailable
      }
      return try await execute(request, plugin: plugin)
    }
  }

  /// 后台组装并运行一次，解析输出。Task 取消时运行器结束进程组并抛 `.cancelled`。
  @concurrent
  private nonisolated static func execute(_ request: ToolBarRunRequest, plugin: ToolPluginRuntimeInfo) async throws
    -> ToolBarOutput
  {
    let invocation = try ScriptToolRunner.makeViewInvocation(
      source: request.source, viewID: request.viewID, trigger: request.trigger, context: request.context,
      plugin: plugin)
    let output = try await ScriptToolRunner.run(invocation)
    return try ToolBarProtocol.parse(output.stdout, pluginDirectory: plugin.directory)
  }
}
