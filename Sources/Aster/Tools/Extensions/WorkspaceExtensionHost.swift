// 每个工作区窗口一份的界面扩展宿主：从工具中心的视图目录挑出本窗口能挂的视图，持有长期存活的 bar、
// 调度器、动作执行器、panel 会话缓存与分支监听；算当前上下文、跟踪窗口可见性。工作区整树重建只借用
// 这里的视图，不重建、不重跑脚本。规则见 docs/developer/tools-and-plugins.md「界面扩展」。
import AppKit
import AsterCore
import Combine

/// 宿主用到的工具中心能力；生产是 `ToolCenter.shared`，测试注入假目录。
@MainActor
protocol ToolViewCatalog: AnyObject {
  /// 视图目录（含用户关掉的，挂载方按 `isMountable` 过滤）。
  var viewEntries: [ToolViewEntry] { get }
  /// 目录、状态或授权变化。
  var changes: AnyPublisher<Void, Never> { get }
  /// 按功能 id（`<pluginID>/<code>`）查可用功能。
  func entry(id: String) -> ToolCatalogEntry?
  /// 弹授权确认；返回是否同意。
  func approve(pluginID: String, window: NSWindow?) async -> Bool
}

extension ToolCenter: ToolViewCatalog {}

/// 界面扩展宿主。只在主线程使用。
@MainActor
final class WorkspaceExtensionHost: ToolPanelProviding {
  /// 本版本由宿主挂 bar 的标签范围位置（`pane.bottom` 每 Pane 一条，见 `paneBar(for:)`；`pane.header` 每 Pane
  /// 一条固定在顶部，见 `paneHeader(for:)`；
  /// `inspector.panel` 由详情面板经 `ToolPanelProviding` 取用）。
  /// `window.*` 与 `activePane.bottom` 的上下文与标签范围相同（窗口选中标签的活动 Pane），共用调度器的 `context`；
  /// `activePane.bottom` 只有一条，由工作区挂到活动终端 Pane 底部，见 `activePaneBarPaneID()`。
  static let mountedBarSlots: [ToolViewSlot] = [.windowTop, .windowBottom, .tabTop, .tabBottom, .activePaneBottom]

  /// 挂了 bar 的位置集合变了（从无到有或从有到无）：工作区需要整树重建一次把条插进去或撤掉。
  var onMountedSlotsChanged: (() -> Void)?
  /// `openPanel` 动作：打开 Inspector 并选中该插件面板（参数是 `ToolViewEntry.id`）。
  var onRevealPanel: ((String) -> Void)?
  /// 所在窗口；弹确认框与判断可见性用。
  var windowProvider: () -> NSWindow? = { nil }

  let scheduler: ToolBarScheduler
  let panelCache: ToolPanelSessionCache
  let branchWatcher = ToolBranchWatcher()
  private(set) var context: ToolBarContext
  private(set) var mountedSlots: Set<ToolViewSlot> = []
  private(set) var inspectorPanelEntries: [ToolViewEntry] = []
  /// 调度中的 bar 视图（可挂载、位置在 `mountedBarSlots`），按目录顺序。
  private(set) var barEntries: [ToolViewEntry] = []
  /// 可挂载的 `pane.bottom` 视图；每个建过视图的终端 Pane 各一份 feed。
  private(set) var paneEntries: [ToolViewEntry] = []
  /// 可挂载的 `pane.header` 视图；同上，与 `paneEntries` 共用 Pane 的上下文。
  private(set) var paneHeaderEntries: [ToolViewEntry] = []
  /// 两种 pane 范围视图，调度、点击与查找都一起处理。
  private var allPaneEntries: [ToolViewEntry] { paneEntries + paneHeaderEntries }
  /// pane feed 键 → Pane。
  private var paneFeedPanes: [String: UUID] = [:]
  /// 当前布局能显示侧栏插件区块（竖排标签栏且标签栏可见）。由工作区在每次整树重建前设置；
  /// 不能显示时 `sidebar.section` 视图不挂载、不建 feed、不建 panel 会话。
  private(set) var isSidebarAvailable = false
  /// 挂到侧栏的视图（bar 与 panel），按目录顺序；侧栏不可用时为空。
  private(set) var sidebarEntries: [ToolViewEntry] = []
  /// 侧栏 bar 视图（`sidebarEntries` 里的 bar），与标签范围的 bar 一样按当前标签取上下文。
  private var sidebarBarEntries: [ToolViewEntry] { sidebarEntries.filter { $0.contribution.kind == .bar } }
  /// 侧栏区块容器；跨整树重建复用。
  let sidebarView = ToolSidebarSectionsView()
  /// 侧栏面板经 `ui.setHeight` 改过的高度；区块重建（声明没变）时沿用。
  private var sidebarPanelHeights: [String: CGFloat] = [:]
  private var sidebarRemountScheduled = false
  private lazy var paneBars: ToolPaneBars = {
    let bars = ToolPaneBars(
      makeBar: { [weak self] _ in
        self?.makeBar(slot: .paneBottom, height: self?.paneBarHeight ?? 24) ?? ToolBarView(slot: .paneBottom, height: 24)
      },
      makeHeader: { [weak self] _ in
        self?.makeBar(slot: .paneHeader, height: self?.paneHeaderHeight ?? 24) ?? ToolBarView(slot: .paneHeader, height: 24)
      })
    bars.onBranchChange = { [weak self] paneID in self?.updatePaneContext(paneID) }
    return bars
  }()

  private weak var model: AppModel?
  private weak var preferences: AppPreferences?
  private let catalog: ToolViewCatalog
  private let services: ToolBridgeServices
  private var bars: [ToolViewSlot: ToolBarView] = [:]
  /// 拖高后的条高，按窗口 suite 记住；`pane.bottom` 所有 Pane 共用一个值。
  let barHeights: ToolBarHeightStore
  private let panelEntriesSubject = PassthroughSubject<Void, Never>()
  private var cancellables: Set<AnyCancellable> = []
  private var tabSubscriptions: Set<AnyCancellable> = []
  private weak var observedTab: TerminalTabItem?
  private var isTornDown = false
  private lazy var performer = makePerformer()

  /// `runner` 为 nil 时用生产运行器（工具中心核对插件后在后台跑脚本）。
  init(
    model: AppModel,
    preferences: AppPreferences,
    catalog: ToolViewCatalog = ToolCenter.shared,
    runner: ToolBarRunner? = nil,
    clock: ToolBarSchedulerClock = .live,
    services: ToolBridgeServices = SystemToolBridgeServices()
  ) {
    self.model = model
    self.preferences = preferences
    self.catalog = catalog
    self.services = services
    barHeights = ToolBarHeightStore(defaults: model.defaults)
    context = ToolBarContext()
    scheduler = ToolBarScheduler(runner: runner ?? ToolBarFeed.liveRunner(), clock: clock)
    panelCache = ToolPanelSessionCache(model: model)
    panelCache.onHeightRequest = { [weak self] id, height in self?.setSidebarPanelHeight(height, entryID: id) }
    scheduler.onFeedChange = { [weak self] id in self?.feedDidChange(id) }
    branchWatcher.onBranchChange = { [weak self] in self?.updateContext() }
    catalog.changes
      .sink { [weak self] in self?.reloadEntries() }
      .store(in: &cancellables)
    model.agentTaskStateChanged
      .sink { [weak self] event in
        self?.updatePaneContext(event.paneID)
        guard let tab = self?.model?.selectedTab, event.tabID == tab.id, event.paneID == tab.activePaneID else { return }
        self?.updateContext()
      }
      .store(in: &cancellables)
    observeWindowVisibility()
    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.teardown() } }
      .store(in: &cancellables)
    reloadEntries()
  }

  var panelEntriesChanged: AnyPublisher<Void, Never> { panelEntriesSubject.eraseToAnyPublisher() }

  // MARK: - 挂载

  /// 某个位置的 bar：没有可挂载视图时为 nil。同一实例跨整树重建复用，交出前先从旧父视图摘下。
  func bar(for slot: ToolViewSlot) -> NSView? {
    guard !isTornDown, mountedSlots.contains(slot), let bar = bars[slot] else { return nil }
    bar.removeFromSuperview()
    return bar
  }

  /// 这个位置有没有可挂载的条（工作区据此决定布局，例如 window.top 接管红绿灯行）。
  func hasBar(for slot: ToolViewSlot) -> Bool {
    !isTornDown && mountedSlots.contains(slot) && bars[slot] != nil
  }

  /// 已建好的 bar（测试用；工作区也用它把 activePane.bottom 条从视图树摘下）。
  func existingBar(for slot: ToolViewSlot) -> ToolBarView? { bars[slot] }

  /// activePane.bottom 条该挂到哪个 Pane：选中标签的活动 Pane，且是终端 Pane（文件、工具、网页 Pane 不挂）；
  /// 没有可挂载视图时为 nil。
  func activePaneBarPaneID() -> UUID? {
    guard hasBar(for: .activePaneBottom), let model, let paneID = model.selectedTab?.activePaneID,
      ToolPaneBars.terminalTab(of: paneID, model: model) != nil
    else { return nil }
    return paneID
  }

  /// 工作区局部改了条的挂载（焦点切换搬 activePane.bottom 条）：重算可见性，条不在窗口里时暂停调度。
  func barMountDidChange() {
    updateVisibility()
  }

  /// 某个 Pane 已建好的 pane.bottom 条（测试用）。
  func existingPaneBar(for paneID: UUID) -> ToolBarView? { paneBars.existingBar(for: paneID) }

  /// 某个 Pane 已建好的 pane.header 条（测试用）。
  func existingPaneHeader(for paneID: UUID) -> ToolBarView? { paneBars.existingHeader(for: paneID) }

  /// 某个 Pane 当前的 pane 上下文（测试用）。
  func paneContext(for paneID: UUID) -> ToolBarContext? { paneBars.contexts[paneID] }

  /// pane.bottom 的条高（点，未缩放）：取第一个视图的声明。
  private var paneBarHeight: Int {
    paneEntries.first?.contribution.barHeight(in: .paneBottom) ?? ToolViewSlot.paneBottom.defaultBarHeight ?? 24
  }

  /// pane.header 的条高（点，未缩放）：取第一个视图的声明。
  private var paneHeaderHeight: Int {
    paneHeaderEntries.first?.contribution.barHeight(in: .paneHeader) ?? ToolViewSlot.paneHeader.defaultBarHeight ?? 24
  }

  /// 某个 Pane 的 pane.bottom 条：没有可挂载视图、Pane 不在选中标签或不是终端 Pane（工具、文件 Pane）时为 nil。
  /// 同一 Pane 跨整树重建复用同一实例，交出前先从旧父视图摘下；第一次挂载时建该 Pane 的 feed。
  func paneBar(for paneID: UUID) -> NSView? {
    guard !isTornDown, !paneEntries.isEmpty, canMountPaneView(paneID) else { return nil }
    let isRegistered = paneBars.contains(paneID)
    let (bar, isNew) = paneBars.bar(for: paneID)
    paneViewDidAppear(paneID, isRegistered: isRegistered, isNew: isNew)
    bar.removeFromSuperview()
    return bar
  }

  /// 某个 Pane 的 pane.header 条：规则同 `paneBar(for:)`，由工作区装到 Pane 顶部，占一行布局空间。
  func paneHeader(for paneID: UUID) -> ToolBarView? {
    guard !isTornDown, !paneHeaderEntries.isEmpty, canMountPaneView(paneID) else { return nil }
    let isRegistered = paneBars.contains(paneID)
    let (header, isNew) = paneBars.header(for: paneID)
    paneViewDidAppear(paneID, isRegistered: isRegistered, isNew: isNew)
    header.removeFromSuperview()
    return header
  }

  /// pane 范围视图只挂在选中标签的终端 Pane 上（工具、文件 Pane 不挂）。
  private func canMountPaneView(_ paneID: UUID) -> Bool {
    guard let model else { return false }
    return model.selectedTab?.layout.descriptor(forPane: paneID) != nil
      && ToolPaneBars.terminalTab(of: paneID, model: model) != nil
  }

  /// 新建了 pane 视图：Pane 第一次登记时算上下文、建 feed；视图新建时画一次当前结果。
  private func paneViewDidAppear(_ paneID: UUID, isRegistered: Bool, isNew: Bool) {
    if !isRegistered, let model {
      _ = paneBars.updateContext(for: paneID, model: model)
      syncFeeds()
    }
    if isNew { renderPane(paneID) }
  }

  /// 工作区整树重建之后：重新订阅当前标签的局部事件、重算上下文（没变不动）、刷新配色与可见性。
  func workspaceDidRefresh() {
    guard !isTornDown else { return }
    observeSelectedTab()
    updateContext()
    refreshPanes()
    bars.values.forEach { $0.refreshAppearance() }
    sidebarView.refreshAppearance()
    paneBars.refreshAppearance()
    updateVisibility()
  }

  /// 整树重建后的 pane 收尾：释放已关闭（或不再是终端）的 Pane，重算选中标签各 Pane 的上下文，
  /// 再按「条挂在窗口里」决定哪些 pane feed 能跑——后台标签的 Pane 不在其中，暂停并记 stale，切回来补跑。
  private func refreshPanes() {
    guard let model else { return }
    let alive = Set(model.tabs.flatMap { tab in tab.layout.allPanes.map(\.id) })
      .filter { ToolPaneBars.terminalTab(of: $0, model: model) != nil }
    if !paneBars.prune(keeping: alive).isEmpty { syncFeeds() }
    let selected = Set(model.selectedTab?.layout.allPanes.map(\.id) ?? [])
    for paneID in paneBars.paneIDs where selected.contains(paneID) { updatePaneContext(paneID) }
    let mounted = windowProvider().map(paneBars.mountedPaneIDs(in:)) ?? []
    scheduler.setVisiblePanes(mounted.intersection(selected))
  }

  /// 重算一个 Pane 的上下文；变了交给调度器（只影响这个 Pane 的 feed）。
  private func updatePaneContext(_ paneID: UUID) {
    guard !isTornDown, let model, let context = paneBars.updateContext(for: paneID, model: model) else { return }
    scheduler.updatePaneContext(context, paneID: paneID)
  }

  /// 把标签范围与 pane 范围的 feed 一起交给调度器（没列出的 feed 被取消）。
  private func syncFeeds() {
    var specs = (barEntries + sidebarBarEntries).map {
      ToolBarFeedSpec(key: $0.id, entry: $0, paneID: nil, context: nil)
    }
    var index: [String: UUID] = [:]
    for paneID in paneBars.paneIDs {
      for entry in allPaneEntries {
        let key = ToolBarScheduler.paneFeedKey(entryID: entry.id, paneID: paneID)
        index[key] = paneID
        specs.append(ToolBarFeedSpec(key: key, entry: entry, paneID: paneID, context: paneBars.contexts[paneID]))
      }
    }
    paneFeedPanes = index
    scheduler.update(specs: specs)
  }

  /// 打开插件面板（`openPanel` 动作）。
  func revealPanel(entryID: String) {
    onRevealPanel?(entryID)
  }

  /// 借出 panel 会话（`ToolPanelProviding`）。
  func panelSession(for entryID: String) -> ToolSessionViewController? {
    guard !isTornDown, let entry = inspectorPanelEntries.first(where: { $0.id == entryID }) else { return nil }
    return panelCache.session(for: entry, context: context)
  }

  /// 窗口关闭：停掉全部脚本（含正在运行的进程组）、网页会话与分支监听。之后不再挂载任何视图。
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    scheduler.teardown()
    panelCache.teardown()
    branchWatcher.stop()
    cancellables.removeAll()
    tabSubscriptions.removeAll()
    bars.values.forEach { $0.apply(segments: []) }
    paneBars.removeAll()
    sidebarView.removeAllBlocks()
    sidebarEntries = []
    mountedSlots = []
  }

  // MARK: - 侧栏

  /// 工作区每次整树重建前告诉宿主当前布局能不能显示侧栏区块。变了就重新挑视图（建或撤 feed 与 panel 会话）；
  /// 这次重建本身就会按新状态取 `sidebarSections`，所以不再请求整树重建。
  func setSidebarAvailable(_ available: Bool) {
    guard !isTornDown, available != isSidebarAvailable else { return }
    isSidebarAvailable = available
    reloadEntries(requestsRefresh: false)
  }

  /// 侧栏插件区块：没有可挂载的侧栏视图（或布局不显示侧栏）时为 nil。同一实例跨整树重建复用，交出前先从旧父视图摘下，
  /// 并换上这次侧栏的 eyebrow 样式。
  func sidebarSections(eyebrowColor: NSColor, eyebrowLeading: CGFloat) -> NSView? {
    guard !isTornDown, isSidebarAvailable, !sidebarEntries.isEmpty else { return nil }
    sidebarView.applyStyle(eyebrowColor: eyebrowColor, eyebrowLeading: eyebrowLeading)
    sidebarView.removeFromSuperview()
    return sidebarView
  }

  /// 按 `sidebarEntries` 对齐区块并重画 bar；panel 区块新建时就借会话挂上。
  private func reloadSidebar() {
    sidebarView.setEntries(sidebarEntries) { entry in
      let height = sidebarPanelHeights[entry.id] ?? ToolSidebarSectionBlock.declaredPanelHeight(entry.contribution)
      let block = ToolSidebarSectionBlock(entry: entry, panelHeight: height)
      if let list = block.listView {
        list.themeProvider = { [weak preferences] in preferences?.activeTheme }
        list.onItem = { [weak self] id, item in self?.perform(item, entryID: id) }
        list.onRetry = { [weak self] id in self?.scheduler.refresh(entryID: id) }
        list.onApprove = { [weak self] id in self?.approve(entryID: id) }
      } else {
        block.mount(panelCache.session(for: entry, context: context))
      }
      return block
    }
    // 声明变了的 panel：缓存在下一轮主队列才拆旧会话，这里再晚一轮重新借，挂上新会话。
    scheduleSidebarRemount()
    sidebarBarEntries.forEach(renderSidebar)
  }

  /// 重画一个侧栏 bar 区块。
  private func renderSidebar(_ entry: ToolViewEntry) {
    sidebarView.block(for: entry.id)?.render(segment(for: entry, key: entry.id))
  }

  /// 下一轮主队列重新借 panel 会话（排在 `ToolPanelSessionCache.reconcile` 的延后拆除之后）。
  private func scheduleSidebarRemount() {
    guard !sidebarRemountScheduled, sidebarEntries.contains(where: { $0.contribution.kind == .panel }) else { return }
    sidebarRemountScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.sidebarRemountScheduled = false
      guard !self.isTornDown else { return }
      for block in self.sidebarView.blocks where block.panelContainer != nil {
        block.mount(self.panelCache.session(for: block.entry, context: self.context))
      }
    }
  }

  /// 侧栏面板请求了新高度：记下并只改该区块的高度约束。
  private func setSidebarPanelHeight(_ height: CGFloat, entryID: String) {
    guard sidebarEntries.contains(where: { $0.id == entryID }) else { return }
    sidebarPanelHeights[entryID] = height
    sidebarView.block(for: entryID)?.setPanelHeight(height)
  }

  // MARK: - 目录

  /// 工具中心变化：挑出本窗口要调度的 bar、侧栏区块与 Inspector 面板；bar 位置（含侧栏）的有无变了才请求整树重建。
  /// `requestsRefresh` 为 false 时（由整树重建本身触发）只更新状态，不再请求重建。
  private func reloadEntries(requestsRefresh: Bool = true) {
    guard !isTornDown else { return }
    let all = catalog.viewEntries
    let sidebar = isSidebarAvailable ? all.filter { $0.isMountable && $0.slot == .sidebarSection } : []
    // 侧栏视图的声明变了：之前 `ui.setHeight` 改过的高度作废，回到清单高度。
    for id in sidebarPanelHeights.keys
    where sidebar.first(where: { $0.id == id })?.contribution != sidebarEntries.first(where: { $0.id == id })?.contribution {
      sidebarPanelHeights[id] = nil
    }
    sidebarEntries = sidebar
    barEntries = all.filter {
      $0.isMountable && $0.contribution.kind == .bar && Self.mountedBarSlots.contains($0.slot)
    }
    paneEntries = all.filter { $0.isMountable && $0.contribution.kind == .bar && $0.slot == .paneBottom }
    paneHeaderEntries = all.filter { $0.isMountable && $0.contribution.kind == .bar && $0.slot == .paneHeader }
    // 没有 pane 视图了：视图全部释放，下次整树重建时 `paneBar(for:)` / `paneHeader(for:)` 返回 nil，Pane 宿主随之撤下。
    // 只剩一种时只释放另一种，Pane 的上下文与分支监听留给还在的那种。
    if allPaneEntries.isEmpty {
      paneBars.removeAll()
    } else if paneEntries.isEmpty {
      paneBars.removeBars()
    } else if paneHeaderEntries.isEmpty {
      paneBars.removeHeaders()
    }
    syncFeeds()
    var slots = Set(barEntries.map(\.slot))
    if !paneEntries.isEmpty { slots.insert(.paneBottom) }
    if !paneHeaderEntries.isEmpty { slots.insert(.paneHeader) }
    if !sidebarEntries.isEmpty { slots.insert(.sidebarSection) }
    for slot in slots where Self.mountedBarSlots.contains(slot) {
      let height = barEntries.first { $0.slot == slot }?.contribution.barHeight(in: slot) ?? 26
      if let bar = bars[slot] { bar.setHeight(height) } else { bars[slot] = makeBar(slot: slot, height: height) }
    }
    Self.mountedBarSlots.forEach(render)
    paneBars.paneIDs.forEach(renderPane)
    // 先让缓存核对（侧栏不可用时侧栏面板不在 `sidebarEntries` 里，其会话随之拆掉），再对齐区块。
    let liveEntries = all.filter { $0.slot != .sidebarSection || sidebar.contains($0) }
    panelCache.reconcile(entries: liveEntries)
    reloadSidebar()
    if slots != mountedSlots {
      mountedSlots = slots
      if requestsRefresh { onMountedSlotsChanged?() }
    }
    let panels = all.filter { $0.isMountable && $0.contribution.kind == .panel && $0.slot == .inspectorPanel }
    if panels != inspectorPanelEntries {
      inspectorPanelEntries = panels
      panelEntriesSubject.send()
    }
    updateVisibility()
  }

  /// 建一条 bar 并接上点击回调。
  private func makeBar(slot: ToolViewSlot, height: Int) -> ToolBarView {
    let bar = ToolBarView(slot: slot, height: height)
    if slot == .windowTop {
      // 红绿灯那一行归 window.top：没有项目也保持 28pt，空白处可以拖动窗口。
      bar.collapsesWhenEmpty = false
      bar.isWindowDragRegion = true
    }
    bar.themeProvider = { [weak preferences] in preferences?.activeTheme }
    bar.onItem = { [weak self] id, item in self?.perform(item, entryID: id) }
    bar.onRetry = { [weak self] id in self?.scheduler.refresh(entryID: id) }
    bar.onApprove = { [weak self] id in self?.approve(entryID: id) }
    bar.restoreHeight(barHeights.height(for: slot))
    bar.onHeightCommit = { [weak self] height in self?.barHeightDidCommit(height, slot: slot) }
    return bar
  }

  /// 条拖高松开或双击复位：按位置记住；`pane.bottom` 共用一个值，其它 Pane 的条跟着变。
  private func barHeightDidCommit(_ height: Double, slot: ToolViewSlot) {
    barHeights.setHeight(height, for: slot)
    guard slot == .paneBottom else { return }
    paneBars.paneIDs.compactMap(paneBars.existingBar(for:)).forEach { $0.restoreHeight(height) }
  }

  /// 某个视图的内容变了：只重画它所在的那条。
  private func feedDidChange(_ id: String) {
    if let paneID = paneFeedPanes[id] {
      renderPane(paneID)
    } else if let slot = barEntries.first(where: { $0.id == id })?.slot {
      render(slot)
    } else if let entry = sidebarBarEntries.first(where: { $0.id == id }) {
      renderSidebar(entry)
    }
  }

  /// 重画一个 Pane 的底部条与顶部条：该 Pane 的每个 pane 视图一段，段 id 是 feed 键。
  private func renderPane(_ paneID: UUID) {
    let segments: ([ToolViewEntry]) -> [ToolBarSegment] = { entries in
      entries.compactMap { self.segment(for: $0, key: ToolBarScheduler.paneFeedKey(entryID: $0.id, paneID: paneID)) }
    }
    if let bar = paneBars.existingBar(for: paneID) {
      bar.setHeight(paneBarHeight)
      bar.apply(segments: segments(paneEntries))
    }
    if let header = paneBars.existingHeader(for: paneID) {
      header.setHeight(paneHeaderHeight)
      header.apply(segments: segments(paneHeaderEntries))
    }
  }

  /// 一个 feed 的当前段。
  private func segment(for entry: ToolViewEntry, key: String) -> ToolBarSegment? {
    guard let feed = scheduler.feed(id: key) else { return nil }
    let content: ToolBarSegment.Content
    switch feed.state {
    case .idle: content = .items([])
    case .ready(let items, _): content = .items(items)
    case .failed(let message, _): content = .failed(message)
    case .needsApproval: content = .needsApproval
    }
    return ToolBarSegment(
      id: key, pluginName: entry.pluginName, iconPath: entry.iconPath, content: content,
      runningSince: feed.runningSince)
  }

  /// feed 键对应的视图与 Pane（标签范围的 Pane 为 nil）。
  private func lookup(_ key: String) -> (entry: ToolViewEntry, paneID: UUID?)? {
    if let paneID = paneFeedPanes[key] {
      return allPaneEntries.first { ToolBarScheduler.paneFeedKey(entryID: $0.id, paneID: paneID) == key }
        .map { ($0, paneID) }
    }
    return (barEntries + sidebarBarEntries).first { $0.id == key }.map { ($0, nil) }
  }

  /// 按 feed 状态生成段并交给条。没有可挂载视图的位置清空（条随之隐藏）。
  private func render(_ slot: ToolViewSlot) {
    guard let bar = bars[slot] else { return }
    bar.apply(segments: barEntries.filter { $0.slot == slot }.compactMap { segment(for: $0, key: $0.id) })
  }

  // MARK: - 点击

  /// 项目点击：交给执行器（`openURL` 要等确认框，所以异步）。pane 条的 `terminal` 写到条所在的 Pane。
  private func perform(_ item: ToolBarItem, entryID key: String) {
    guard let action = item.action, let (entry, paneID) = lookup(key) else { return }
    let terminal = paneID.flatMap { paneID in model.flatMap { ToolPaneBars.terminal(of: paneID, model: $0) } }
    Task { [weak self] in await self?.performer.perform(action, from: entry, feedKey: key, terminal: terminal) }
  }

  /// 「需要授权」：弹工具中心的授权确认；同意后目录变化会让视图按 `manual` 重跑。
  private func approve(entryID key: String) {
    guard let entry = lookup(key)?.entry else { return }
    let window = windowProvider()
    Task { [weak self] in _ = await self?.catalog.approve(pluginID: entry.pluginID, window: window) }
  }

  /// 生产执行器：剪贴板与确认框走系统服务，终端写到当前活动 Pane，功能经工具面板打开，提示走窗口 toast。
  private func makePerformer() -> ToolBarActionPerformer {
    ToolBarActionPerformer(
      services: services,
      terminal: { [weak self] in self?.model?.toolTerminalOrigin() },
      viewEntries: { [weak self] in self?.catalog.viewEntries ?? [] },
      featureEntry: { [weak self] id in self?.catalog.entry(id: id) },
      launchFeature: { [weak self] feature, text in self?.launchFeature(feature, text: text) },
      revealPanel: { [weak self] id in self?.revealPanel(entryID: id) },
      refresh: { [weak self] id in self?.scheduler.refresh(entryID: id) },
      notify: { [weak self] message in self?.model?.notice = message },
      window: { [weak self] in self?.windowProvider() })
  }

  /// `feature` 动作：在工具面板里打开同插件的功能，输入文本可选，来源终端是当前活动 Pane。
  private func launchFeature(_ feature: ToolCatalogEntry, text: String?) {
    guard let model else { return }
    let origin = model.toolTerminalOrigin()
    let input = ToolInput(text: text, source: text == nil ? .none : .typed, context: model.toolContext(for: origin))
    NotificationCenter.default.post(
      name: .asterShowToolLauncher,
      object: ToolLauncherRequestBox(request: ToolLaunchRequest(entry: feature, input: input, origin: origin)))
  }

  // MARK: - 上下文

  /// 订阅当前标签的局部事件（不进 `objectWillChange`）：活动 Pane、活动 Pane 的目录与远端状态。
  private func observeSelectedTab() {
    guard let tab = model?.selectedTab else {
      observedTab = nil
      tabSubscriptions.removeAll()
      return
    }
    guard tab !== observedTab else { return }
    observedTab = tab
    tabSubscriptions.removeAll()
    // 活动 Pane 切换只影响标签范围视图；pane 视图的上下文是它自己的 Pane，切换焦点不重跑。
    tab.activePaneChanged
      .sink { [weak self] _ in self?.updateContext() }
      .store(in: &tabSubscriptions)
    // 目录与远端变化：活动 Pane 的驱动标签范围视图，任何挂着 pane 条的 Pane 驱动它自己的 pane 视图。
    tab.workingDirectoryChanged
      .sink { [weak self, weak tab] change in
        if change.paneID == tab?.activePaneID { self?.updateContext() }
        self?.updatePaneContext(change.paneID)
      }
      .store(in: &tabSubscriptions)
    tab.remoteContextChanged
      .sink { [weak self, weak tab] paneID in
        if paneID == tab?.activePaneID { self?.updateContext() }
        self?.updatePaneContext(paneID)
      }
      .store(in: &tabSubscriptions)
  }

  /// 重算上下文；变了才交给调度器与 panel 会话。分支来自分支监听（后台读、按仓库去重）。
  private func updateContext() {
    guard !isTornDown, let model else { return }
    var next = Self.makeContext(model: model)
    branchWatcher.watch(directory: next.workingDirectory)
    next.branch = branchWatcher.branch(for: next.workingDirectory)
    guard next != context else { return }
    context = next
    scheduler.updateContext(next)
    panelCache.updateContext(next)
  }

  /// 当前标签活动 Pane 的上下文：本机终端才有工作目录（远端为 nil 并标 `isRemote`），locale / appearance
  /// 与工具一致；Agent 只在活动 Pane 跑着 Agent 时有。分支由调用方补。
  static func makeContext(model: AppModel) -> ToolBarContext {
    let origin = model.toolTerminalOrigin()
    let tool = model.toolContext(for: origin)
    guard let tab = model.selectedTab else {
      return ToolBarContext(isRemote: tool.isRemote, locale: tool.locale, appearance: tool.appearance)
    }
    var agent: ToolBarAgentContext?
    if let session = tab.activeSession, let provider = session.activeAgentProvider {
      agent = ToolBarAgentContext(
        provider: provider.rawValue, state: session.agentTaskState.rawValue, sessionID: session.activeAgentSessionID)
    }
    return ToolBarContext(
      workingDirectory: tool.workingDirectory, isRemote: tool.isRemote, locale: tool.locale,
      appearance: tool.appearance, tabID: tab.id.uuidString, paneID: tab.activePaneID.uuidString, agent: agent)
  }

  // MARK: - 可见性

  /// 窗口遮挡、最小化与关闭都会改变可见性；只认自己的窗口。
  private func observeWindowVisibility() {
    let names: [Notification.Name] = [
      NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
      NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
    ]
    for name in names {
      NotificationCenter.default.publisher(for: name)
        .sink { [weak self] notification in
          MainActor.assumeIsolated {
            guard let self, let window = notification.object as? NSWindow, window === self.windowProvider() else {
              return
            }
            self.updateVisibility(closing: name == NSWindow.willCloseNotification)
          }
        }
        .store(in: &cancellables)
    }
  }

  /// 可见 = 窗口在屏幕上、没被完全遮挡、没最小化，且条确实挂在这个窗口里（主机页等占据内容区时不挂）。
  private func updateVisibility(closing: Bool = false) {
    guard !isTornDown else { return }
    guard !closing, let window = windowProvider() else {
      scheduler.isVisible = false
      return
    }
    let onScreen = window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
    scheduler.isVisible =
      onScreen
      && (bars.values.contains { $0.window === window } || !paneBars.mountedPaneIDs(in: window).isEmpty
        || sidebarView.window === window)
  }
}
