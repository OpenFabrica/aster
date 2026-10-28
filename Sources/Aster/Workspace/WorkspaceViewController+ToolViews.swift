// 工作区窗口与插件界面扩展的挂载胶水：把扩展宿主接到窗口、整树刷新与 Inspector，并给 window.* 条包外层。
// tab.* 的插入点在 WorkspaceView.swift 的 makeTerminalWorkspace（tab.top 在查找条之后，tab.bottom 在 composer 之后）；
// window.* 在 makeWorkspaceLayout 的顶层 split 外面（见 `wrapWithWindowBars`）。
import AppKit
import AsterCore

/// 插件 window.top 条的几何：与红绿灯同一行。
enum WindowTopBarMetrics {
  /// 条高（点），等于标题栏那一行，不随界面字号缩放。
  static let height: CGFloat = 28
  /// 红绿灯右侧到第一项的间距。
  static let trafficLightGap: CGFloat = 12
  /// 取不到缩放按钮位置时的左内边距（标准窗口红绿灯右缘约 66）。
  static let fallbackLeadingInset: CGFloat = 78
  /// 全屏时红绿灯隐藏，只留普通内边距。
  static let fullScreenLeadingInset: CGFloat = 8
}

extension WorkspaceViewController {
  /// viewDidLoad 时接线：窗口用于可见性与确认框；bar 位置的有无变化合并成一次整树刷新（内容变化只重画条本身）；
  /// `openPanel` 动作打开 Inspector 并选中插件面板。
  func installToolViewHost() {
    extensionHost.windowProvider = { [weak self] in self?.viewIfLoaded?.window }
    extensionHost.onMountedSlotsChanged = { [weak self] in self?.scheduleRefresh() }
    extensionHost.onRevealPanel = { [weak self] entryID in self?.revealPluginPanel(entryID: entryID) }
  }

  /// 打开 Inspector（经模型的局部展示事件，不触发整树重建）并选中插件面板页签。
  func revealPluginPanel(entryID: String) {
    model.isInspectorPresented = true
    detailsControllerForSelectedTab().selectPluginPanel(entryID: entryID)
  }

  /// 给顶层布局包上 window.top / window.bottom：纵向 `[top?, content, bottom?]`，全宽。没有条时原样返回 `content`，
  /// 布局与没有界面扩展时完全一样。`.bottom` 标签布局的标签栏在 `content` 里，window.bottom 因此在它下面（窗口最底）。
  func wrapWithWindowBars(_ content: NSView, top: NSView?, bottom: NSView?) -> NSView {
    guard top != nil || bottom != nil else { return content }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .width
    stack.distribution = .fill
    stack.spacing = 0
    let topBand = top.map(makeWindowBarBackground)
    let bottomBand = bottom.map(makeWindowBarBackground)
    for member in [topBand, content, bottomBand].compactMap({ $0 }) { stack.addArrangedSubview(member) }
    // 与 makeTerminalWorkspace 同理：内容（顶层 split）没有固有尺寸，两个方向都要必需约束，
    // 否则 NSSplitView 的 `== 0 @250` 回退约束会把它压扁；约束必须在入栈之后建立。
    content.translatesAutoresizingMaskIntoConstraints = false
    content.setContentHuggingPriority(.defaultLow, for: .vertical)
    content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    var constraints = [
      content.topAnchor.constraint(equalTo: topBand?.bottomAnchor ?? stack.topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomBand?.topAnchor ?? stack.bottomAnchor),
    ]
    if let topBand { constraints.append(topBand.topAnchor.constraint(equalTo: stack.topAnchor)) }
    if let bottomBand { constraints.append(bottomBand.bottomAnchor.constraint(equalTo: stack.bottomAnchor)) }
    for member in [topBand, content, bottomBand].compactMap({ $0 }) {
      member.translatesAutoresizingMaskIntoConstraints = false
      constraints.append(member.widthAnchor.constraint(equalTo: stack.widthAnchor))
    }
    NSLayoutConstraint.activate(constraints)
    updateWindowTopBarInset()
    return stack
  }

  /// window.* 条的底：标签栏同一套 material 与 `tabbar.background` 回退链（同 makeHorizontalTabBar），
  /// 透明主题下与窗口玻璃连成一片。条自己画 1pt `interface.border` 分隔线；底跟着条高（window.bottom 没项目时为 0）。
  private func makeWindowBarBackground(_ bar: NSView) -> NSView {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    background.identifier = NSUserInterfaceItemIdentifier("workspace-window-bar-background")
    background.apply(
      material: theme.style.horizontalTabBarMaterial ?? theme.palette.material,
      tint: theme.resolvedColor(forSlot: "tabbar.background")
        ?? theme.style.horizontalTabBarBackground ?? theme.style.sidebarBackground
          ?? theme.palette.panelBackground
    )
    background.addSubview(bar)
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.pinEdges(to: background)
    return background
  }

  /// window.top 条的左内边距：红绿灯缩放按钮右缘 + 12；取不到按钮用 78；全屏时红绿灯隐藏，只留 8。
  /// viewDidLayout 与每次重建时重算，窗口缩放、全屏切换都会经过这里。
  func updateWindowTopBarInset() {
    guard let bar = extensionHost.existingBar(for: .windowTop) else { return }
    bar.leadingInset = Self.windowTopBarLeadingInset(for: view.window)
  }

  /// 按窗口的红绿灯位置算 window.top 的左内边距。
  static func windowTopBarLeadingInset(for window: NSWindow?) -> CGFloat {
    guard let window else { return WindowTopBarMetrics.fallbackLeadingInset }
    if window.styleMask.contains(.fullScreen) { return WindowTopBarMetrics.fullScreenLeadingInset }
    guard let zoom = window.standardWindowButton(.zoomButton), let superview = zoom.superview, !zoom.isHidden
    else { return WindowTopBarMetrics.fallbackLeadingInset }
    let frame = superview.convert(zoom.frame, to: nil)
    guard frame.maxX > 0 else { return WindowTopBarMetrics.fallbackLeadingInset }
    return ceil(frame.maxX) + WindowTopBarMetrics.trafficLightGap
  }
}
