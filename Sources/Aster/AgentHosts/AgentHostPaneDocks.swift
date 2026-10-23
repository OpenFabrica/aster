// 停靠在 Pane 底部的 agent 主机终端：按 Pane UUID 记停靠区（视图、终端条目、选中项、收起、高度比例）。
// 停靠区视图长期存在，不随工作区 refresh 重建；工作区每次重建 Pane 后按 Pane UUID 把它装回去，
// 局部变化（出现、消失、收起、调高度）经 `changes` 通知工作区单独装卸，不整树重建。
import AppKit
import Combine

/// 停靠区注册表。生产用 `shared`，测试各建一份。
@MainActor
final class AgentHostPaneDocks {
  static let shared = AgentHostPaneDocks()

  /// 停靠区里的一个终端。
  struct Item {
    let terminalID: String
    /// 终端 + 遮罩 + 控制胶囊；选中且展开时装进停靠区。
    let content: NSView
    var tab: AgentHostPaneDockView.Tab
    /// 用户点了「弹出为独立窗口」。
    let popOut: @MainActor () -> Void
  }

  /// 工作区装停靠区要的东西。
  struct Mount {
    let view: AgentHostPaneDockView
    let height: ActivePaneHostView.DockHeight
  }

  /// 展开时默认占 Pane 高度的比例，以及拖动可调的范围。
  static let defaultHeightRatio: CGFloat = 0.4
  static let heightRatioRange: ClosedRange<CGFloat> = 0.2...0.75
  /// 展开时至少这么高（约 10 行）：agent 的探针只读可见屏幕，太矮既看不清，也读不全输出。
  static let minimumExpandedHeight: CGFloat = 200
  /// 给上方 Pane 内容至少留这么高；Pane 太矮时先压停靠区。
  static let contentReserve: CGFloat = 100

  /// 一个 Pane 的停靠区。嵌套类型不继承外层的主线程隔离，要单独标注。
  @MainActor
  private final class Dock {
    let view = AgentHostPaneDockView()
    var items: [Item] = []
    var selectedID: String?
    var collapsed = false
    var heightRatio = AgentHostPaneDocks.defaultHeightRatio
  }

  private var docks: [UUID: Dock] = [:]
  private let changeSubject = PassthroughSubject<UUID, Never>()

  /// 某个 Pane 的停靠区要重新装（出现、消失、收起、改高度）；值是 Pane UUID。
  var changes: AnyPublisher<UUID, Never> { changeSubject.eraseToAnyPublisher() }

  /// 有停靠区的 Pane。
  var paneIDs: [UUID] { Array(docks.keys) }

  // MARK: - 条目

  /// 把终端停到 Pane 底部，选中它并展开停靠区。
  func attach(_ item: Item, to paneID: UUID) {
    detach(item.terminalID)
    let dock = docks[paneID] ?? makeDock(for: paneID)
    dock.items.append(item)
    dock.selectedID = item.terminalID
    dock.collapsed = false
    render(paneID, remount: true)
  }

  /// 从停靠区摘掉终端；停靠区空了就整个撤掉。内容视图若还挂在停靠区里会被摘下来。
  func detach(_ terminalID: String) {
    guard let paneID = paneID(of: terminalID), let dock = docks[paneID] else { return }
    dock.items.removeAll { $0.terminalID == terminalID }
    if dock.items.isEmpty {
      docks[paneID] = nil
      dock.view.apply(tabs: [], selectedID: nil, content: nil, collapsed: dock.collapsed)
      dock.view.removeFromSuperview()
      changeSubject.send(paneID)
      return
    }
    if dock.selectedID == terminalID { dock.selectedID = dock.items.last?.terminalID }
    // 摘掉的可能正是键盘焦点所在的终端：也通知工作区，让它把落空的焦点交还活动 Pane。
    render(paneID, remount: true)
  }

  /// 状态变化：只刷新标签，不动布局。终端每次状态变化都会调到这里，没变就什么也不做。
  func update(_ terminalID: String, tab: AgentHostPaneDockView.Tab) {
    guard let paneID = paneID(of: terminalID), let dock = docks[paneID],
      let index = dock.items.firstIndex(where: { $0.terminalID == terminalID }),
      dock.items[index].tab != tab
    else { return }
    dock.items[index].tab = tab
    render(paneID, remount: false)
  }

  /// 选中并展开（新命令、等输入、窗口菜单找回、点标签）。
  func reveal(_ terminalID: String) {
    guard let paneID = paneID(of: terminalID), let dock = docks[paneID],
      dock.selectedID != terminalID || dock.collapsed
    else { return }
    dock.selectedID = terminalID
    dock.collapsed = false
    render(paneID, remount: true)
  }

  /// 收起只剩头部，或展开。
  func setCollapsed(_ collapsed: Bool, paneID: UUID) {
    guard let dock = docks[paneID], dock.collapsed != collapsed else { return }
    dock.collapsed = collapsed
    render(paneID, remount: true)
  }

  /// 拖动调高度；比例夹在 `heightRatioRange` 里。
  func setHeightRatio(_ ratio: CGFloat, paneID: UUID) {
    guard let dock = docks[paneID] else { return }
    let clamped = min(max(ratio, Self.heightRatioRange.lowerBound), Self.heightRatioRange.upperBound)
    guard abs(clamped - dock.heightRatio) > 0.001 else { return }
    dock.heightRatio = clamped
    changeSubject.send(paneID)
  }

  // MARK: - 查询

  /// 工作区装停靠区用；没有终端时为 nil（撤掉停靠区）。
  func mount(for paneID: UUID) -> Mount? {
    guard let dock = docks[paneID] else { return nil }
    let height = ActivePaneHostView.DockHeight(
      ratio: dock.heightRatio, minimum: Self.minimumExpandedHeight, contentReserve: Self.contentReserve,
      collapsedHeight: dock.collapsed ? AgentHostPaneDockView.headerHeight : nil)
    return Mount(view: dock.view, height: height)
  }

  /// 终端停在哪个 Pane。
  func paneID(of terminalID: String) -> UUID? {
    docks.first { $0.value.items.contains { $0.terminalID == terminalID } }?.key
  }

  /// `view` 在哪个 Pane 的停靠区里（沿 superview 找停靠区视图）；不在任何停靠区里为 nil。
  func paneID(containing view: NSView) -> UUID? {
    var candidate: NSView? = view
    while let current = candidate {
      if let dockView = current as? AgentHostPaneDockView {
        return docks.first { $0.value.view === dockView }?.key
      }
      candidate = current.superview
    }
    return nil
  }

  /// key 窗口的焦点落在哪个 Pane 的停靠区里。
  func paneID(owningKeyboardIn window: NSWindow) -> UUID? {
    guard let responder = window.firstResponder as? NSView else { return nil }
    return paneID(containing: responder)
  }

  /// 关闭快捷键：焦点在停靠区里就收起它并返回 true，不关 agent 的 Pane；否则返回 false。
  func handleCloseShortcut(in window: NSWindow) -> Bool {
    guard let paneID = paneID(owningKeyboardIn: window) else { return false }
    setCollapsed(true, paneID: paneID)
    return true
  }

  /// 停靠区当前状态；测试与调试用。
  func state(for paneID: UUID) -> (terminalIDs: [String], selectedID: String?, collapsed: Bool, heightRatio: CGFloat)? {
    guard let dock = docks[paneID] else { return nil }
    return (dock.items.map(\.terminalID), dock.selectedID, dock.collapsed, dock.heightRatio)
  }

  // MARK: - 私有

  /// 新建停靠区并接上头部按钮。
  private func makeDock(for paneID: UUID) -> Dock {
    let dock = Dock()
    dock.view.onSelect = { [weak self] terminalID in self?.reveal(terminalID) }
    dock.view.onToggleCollapsed = { [weak self, weak dock] in
      guard let self, let dock else { return }
      self.setCollapsed(!dock.collapsed, paneID: paneID)
    }
    dock.view.onPopOut = { [weak dock] in
      guard let dock, let selected = dock.items.first(where: { $0.terminalID == dock.selectedID }) else { return }
      selected.popOut()
    }
    dock.view.onResize = { [weak self] ratio in self?.setHeightRatio(ratio, paneID: paneID) }
    docks[paneID] = dock
    return dock
  }

  /// 把条目、选中项与收起状态交给视图；高度、显隐或显示的终端变了（`remount`）再通知工作区重装。
  private func render(_ paneID: UUID, remount: Bool) {
    guard let dock = docks[paneID] else { return }
    let selected = dock.items.first { $0.terminalID == dock.selectedID }
    dock.view.apply(
      tabs: dock.items.map(\.tab), selectedID: dock.selectedID, content: selected?.content, collapsed: dock.collapsed)
    if remount { changeSubject.send(paneID) }
  }
}
