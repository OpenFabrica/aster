// 界面扩展的原生横条：同一挂载点的所有 bar 视图共用一条，每个视图一段，段间 1pt 竖分隔。
// 由 WorkspaceExtensionHost 长期持有，工作区整树重建时只换父视图；内容变化只调 `apply(segments:)`。
// 单行放不下时左右滚动；可拖高的位置拖边缘按整行拉高，项目自动换行，超出可见行数时上下滚动。
// 全部为空时整条隐藏且高度归零，不在终端下面留空白。
import AppKit
import AsterCore

/// 条上的一段：一个视图当前要显示的内容。
struct ToolBarSegment: Equatable {
  enum Content: Equatable {
    case items([ToolBarItem])
    /// 最近一次运行失败，附错误摘要。
    case failed(String)
    case needsApproval
  }

  /// `ToolViewEntry.id`。
  let id: String
  let pluginName: String
  /// 失败时显示的插件（或视图）图标。
  let iconPath: String?
  let content: Content
  /// 正在运行时的开始时间。
  let runningSince: Date?

  /// 没有可显示的东西：这一段不占位置。
  var isEmpty: Bool {
    if case .items(let items) = content { return items.isEmpty }
    return false
  }
}

/// 原生 bar。只在主线程使用。
@MainActor
final class ToolBarView: NSView {
  /// 运行超过这么久才显示 spinner，脚本很快时不闪。
  static let spinnerDelay: TimeInterval = 1
  /// 拖高把手的命中带厚度（点）。
  static let resizeHandleThickness: CGFloat = 4

  let slot: ToolViewSlot
  /// 点了带动作的项目（段 id、项目）。
  var onItem: ((_ segmentID: String, _ item: ToolBarItem) -> Void)?
  /// 点了失败段：重跑。
  var onRetry: ((_ segmentID: String) -> Void)?
  /// 点了「需要授权」。
  var onApprove: ((_ segmentID: String) -> Void)?
  /// 拖高松开或双击复位后的条高（未缩放点，= 行数 × 清单行高）；宿主据此持久化。拖动过程中不回调。
  var onHeightCommit: ((Double) -> Void)?
  /// 当前主题；nil 时用 `AsterTheme` 动态色。
  var themeProvider: (() -> TerminalTheme?)?
  /// 判断 spinner 是否到时（测试可替换）。
  var now: () -> Date = { Date() }
  /// 全部段为空时是否隐藏整条并把高度归零。`window.top` 不收起：红绿灯那一行归它，收起后侧栏与内容会顶到红绿灯下面。
  var collapsesWhenEmpty = true {
    didSet { updateEmptiness() }
  }
  /// 左内边距（点）。`window.top` 由工作区按红绿灯位置设置；其余位置用缺省 8。
  var leadingInset: CGFloat? {
    didSet { if leadingInset != oldValue { needsLayout = true } }
  }
  /// 空白处可以拖动窗口、双击缩放（`window.top` 占着标题栏那一行，系统标题栏的手势要手动补回）。
  var isWindowDragRegion = false

  private(set) var segments: [ToolBarSegment] = []
  /// 按「段 id + 项目 id（没有就用序号）」复用的按钮：跨刷新保持悬停态。
  private var buttons: [String: ToolBarItemButton] = [:]
  /// 每个非空段的按钮，按显示顺序。
  private var groups: [(segment: ToolBarSegment, buttons: [ToolBarItemButton])] = []
  private var spinners: [String: NSProgressIndicator] = [:]
  /// 内容放在滚动视图里：单行横向滚，多行纵向滚。按钮、spinner、分隔线都是 `contentView` 的子视图。
  let scrollView = ToolBarScrollView()
  private let contentView = ToolBarContentView()
  /// 可拖高的位置才有；`window.top` 等为 nil。
  private(set) var resizeHandle: ToolBarResizeHandle?
  private let edgeLine = CALayer()
  private var separatorViews: [NSView] = []
  private var heightConstraint: NSLayoutConstraint!
  /// 清单里的单行高度（未缩放点）；持久化与行数夹取都用这个单位。
  private var rowHeightPoints: Int
  /// 单行高度（缩放后）。
  private var barHeight: CGFloat
  /// 当前显示几行；不可拖高的位置恒为 1。
  private(set) var rows = 1
  /// 拖动开始时的行数，位移按它换算。
  private var dragStartRows = 1
  /// 悬停或拖动把手时边线用强调色。
  private var isEdgeHighlighted = false {
    didSet { if isEdgeHighlighted != oldValue { needsDisplay = true } }
  }
  private var spinnerWork: DispatchWorkItem?

  /// `height` 是清单里的条高（点，未缩放）。
  init(slot: ToolViewSlot, height: Int) {
    self.slot = slot
    rowHeightPoints = height
    barHeight = Self.scaledHeight(height, slot: slot)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("tool-bar-\(slot.rawValue)")
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    layer?.addSublayer(edgeLine)
    contentView.owner = self
    scrollView.documentView = contentView
    addSubview(scrollView)
    if ToolBarHeightPolicy.isResizable(slot) { installResizeHandle() }
    heightConstraint = heightAnchor.constraint(equalToConstant: barHeight)
    heightConstraint.isActive = true
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel(L("插件状态条"))
    isHidden = true
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 换单行条高（清单变化）；已拉高的行数保留，按新行高重算总高。
  func setHeight(_ height: Int) {
    rowHeightPoints = height
    barHeight = Self.scaledHeight(height, slot: slot)
    applyRows(clampedRows(rows))
  }

  /// 条高随界面字号缩放；window.top 与红绿灯同一行，几何由窗口决定，不缩放。
  private static func scaledHeight(_ height: Int, slot: ToolViewSlot) -> CGFloat {
    slot == .windowTop ? CGFloat(height) : InterfaceScale.length(CGFloat(height))
  }

  /// 当前应占的高度：行数 × 单行高度。
  private var visibleHeight: CGFloat { barHeight * CGFloat(rows) }

  /// 隐藏时高度归零：插入点的约束链是必需约束，隐藏视图仍参与布局，不归零会在终端下留一条空白。
  override var isHidden: Bool {
    didSet { heightConstraint?.constant = isHidden ? 0 : visibleHeight }
  }

  // MARK: - 拖高

  /// 套用记住的高度（未缩放点）：吸附成整行并夹到 1…上限；nil 或坏值回到单行。不回调 `onHeightCommit`。
  func restoreHeight(_ height: Double?) {
    guard resizeHandle != nil else { return }
    applyRows(ToolBarHeightPolicy.rows(forHeight: height ?? 0, rowHeight: Double(rowHeightPoints)))
  }

  /// 把行数夹到 1…该行高下的上限；不可拖高的位置恒为 1。
  private func clampedRows(_ rows: Int) -> Int {
    guard resizeHandle != nil else { return 1 }
    return ToolBarHeightPolicy.rows(
      forHeight: Double(rows * rowHeightPoints), rowHeight: Double(rowHeightPoints))
  }

  /// 改行数：只动条自己的高度约束并重排，不触发工作区整树重建、不重跑脚本。
  private func applyRows(_ newRows: Int) {
    rows = newRows
    heightConstraint.constant = isHidden ? 0 : visibleHeight
    needsLayout = true
  }

  /// 挂上边缘把手：底部类位置在上边缘，`tab.top` 在下边缘。
  private func installResizeHandle() {
    let handle = ToolBarResizeHandle(edge: slot == .tabTop ? .bottom : .top)
    handle.onDragBegan = { [weak self] in self?.dragStartRows = self?.rows ?? 1 }
    handle.onDrag = { [weak self] delta in self?.drag(by: delta) }
    handle.onDragEnded = { [weak self] in self?.endDrag() }
    handle.onReset = { [weak self] in self?.resetToSingleRow() }
    handle.onHighlightChange = { [weak self] highlighted in self?.isEdgeHighlighted = highlighted }
    addSubview(handle)
    resizeHandle = handle
  }

  /// 拖动中：按下时的高度加位移，换算成未缩放点后吸附成整行（过半行才跳），实时改高度约束。
  func drag(by delta: CGFloat) {
    guard barHeight > 0 else { return }
    let proposed = (CGFloat(dragStartRows) * barHeight + delta) / barHeight * CGFloat(rowHeightPoints)
    let next = ToolBarHeightPolicy.rows(forHeight: Double(proposed), rowHeight: Double(rowHeightPoints))
    if next != rows { applyRows(next) }
  }

  /// 松开：行数真的变了才持久化。
  func endDrag() {
    if rows != dragStartRows { commitHeight() }
  }

  /// 双击边缘：恢复单行并持久化。
  func resetToSingleRow() {
    applyRows(1)
    commitHeight()
  }

  /// 把当前高度交给宿主保存。
  private func commitHeight() {
    onHeightCommit?(Double(rows * rowHeightPoints))
  }

  // MARK: - 内容

  /// 换上全部段。按钮按键复用；全部为空时隐藏整条。
  func apply(segments newSegments: [ToolBarSegment]) {
    segments = newSegments
    var reused: [String: ToolBarItemButton] = [:]
    groups = []
    for segment in newSegments where !segment.isEmpty {
      var segmentButtons: [ToolBarItemButton] = []
      for (key, content) in Self.contents(of: segment) {
        let button = buttons[key] ?? makeButton()
        button.configure(content)
        button.onPress = pressHandler(segmentID: segment.id, content: content)
        reused[key] = button
        if button.hasContent { segmentButtons.append(button) } else { button.isHidden = true }
      }
      groups.append((segment, segmentButtons))
    }
    for (key, button) in buttons where reused[key] == nil { button.removeFromSuperview() }
    buttons = reused
    let liveSpinnerIDs = Set(groups.map(\.segment.id))
    for (id, spinner) in spinners where !liveSpinnerIDs.contains(id) {
      spinner.removeFromSuperview()
      spinners[id] = nil
    }
    updateEmptiness()
    scheduleSpinnerReveal()
    refreshAppearance()
    needsLayout = true
  }

  /// 没有任何可显示的按钮时按 `collapsesWhenEmpty` 收起。
  private func updateEmptiness() {
    isHidden = collapsesWhenEmpty && groups.allSatisfy { $0.buttons.isEmpty }
  }

  /// 没有内容（测试与布局用）：与是否收起无关。
  var isEmpty: Bool { groups.allSatisfy { $0.buttons.isEmpty } }

  /// 一段要显示的按钮内容与复用键。侧栏的纵向列表 `ToolBarListView` 共用同一套规则。
  static func contents(of segment: ToolBarSegment) -> [(String, ToolBarItemButton.Content)] {
    switch segment.content {
    case .items(let items):
      return items.enumerated().map { index, item in
        ("\(segment.id)#\(item.id.map { "id:\($0)" } ?? "index:\(index)")", .item(item))
      }
    case .failed(let message):
      return [("\(segment.id)#failure", .failure(message: message, iconPath: segment.iconPath))]
    case .needsApproval:
      return [("\(segment.id)#approval", .approval(pluginName: segment.pluginName))]
    }
  }

  /// 按钮点击的去向。没有动作的项目只是展示。
  private func pressHandler(segmentID: String, content: ToolBarItemButton.Content) -> (() -> Void)? {
    switch content {
    case .item(let item):
      guard item.action != nil else { return nil }
      return { [weak self] in self?.onItem?(segmentID, item) }
    case .failure: return { [weak self] in self?.onRetry?(segmentID) }
    case .approval: return { [weak self] in self?.onApprove?(segmentID) }
    }
  }

  /// 新按钮挂进内容层，配色跟当前主题。
  private func makeButton() -> ToolBarItemButton {
    let button = ToolBarItemButton()
    contentView.addSubview(button)
    return button
  }

  /// 主题或外观变了：重新解析颜色并推给每个按钮。
  func refreshAppearance() {
    let palette = ToolBarPalette.resolve(theme: themeProvider?())
    for button in buttons.values { button.palette = palette }
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  // MARK: - spinner

  /// 运行中但还没满 1 s 的段：到点后重新布局一次，让 spinner 出现。只在有运行时排一次性任务。
  private func scheduleSpinnerReveal() {
    spinnerWork?.cancel()
    spinnerWork = nil
    let now = now()
    let waits = groups.compactMap { group -> TimeInterval? in
      guard let since = group.segment.runningSince else { return nil }
      let remaining = Self.spinnerDelay - now.timeIntervalSince(since)
      return remaining > 0 ? remaining : nil
    }
    guard let wait = waits.min() else { return }
    let work = DispatchWorkItem { [weak self] in self?.needsLayout = true }
    spinnerWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
  }

  /// 这一段此刻是否显示 spinner。
  private func showsSpinner(_ segment: ToolBarSegment) -> Bool {
    guard let since = segment.runningSince else { return false }
    return now().timeIntervalSince(since) >= Self.spinnerDelay
  }

  /// 取（或建）一段的 spinner。
  private func spinner(for segmentID: String) -> NSProgressIndicator {
    if let spinner = spinners[segmentID] { return spinner }
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .mini
    spinner.isDisplayedWhenStopped = false
    contentView.addSubview(spinner)
    spinners[segmentID] = spinner
    return spinner
  }

  // MARK: - 布局

  /// 手工排版：左内边距 8，项目间距 2，段间 6 + 1pt 分隔 + 6，右侧留 8。
  /// 单行：全部排成一行，内容比条宽时左右滚动（不再收进「…」菜单）。
  /// 多行：流式换行，行高 = 单行高度，内容超出可见行数时上下滚动。顺序始终与脚本输出一致。
  override func layout() {
    super.layout()
    scrollView.frame = bounds
    // 立即铺好 clip view：下面要按可见尺寸排版，并在本次布局内夹回滚动位置。
    scrollView.tile()
    layoutResizeHandle()
    let clipSize = scrollView.contentSize
    let inset = leadingInset ?? InterfaceScale.length(8)
    let trailing = InterfaceScale.length(8)
    let spacing = InterfaceScale.length(2)
    let separatorGap = InterfaceScale.length(6)
    let separatorWidth = separatorGap * 2 + 1
    let wraps = rows > 1
    // 单行时按实际条高居中（测试与 window.top 的条高不一定等于清单行高）；多行时每行一个清单行高。
    let lineHeight = wraps ? barHeight : clipSize.height
    let buttonHeight = max(0, min(lineHeight - InterfaceScale.length(4), InterfaceScale.length(22)))
    let spinnerSide = InterfaceScale.length(10)
    func width(of view: NSView) -> CGFloat {
      view is NSProgressIndicator ? spinnerSide : ceil(view.intrinsicContentSize.width)
    }

    var x = inset
    var line = 0
    var maxX: CGFloat = 0
    var separators: [(x: CGFloat, line: Int)] = []
    for (segmentIndex, views) in layoutPlan().enumerated() {
      for (index, view) in views.enumerated() {
        let viewWidth = width(of: view)
        var leading = index > 0 ? spacing : (segmentIndex > 0 ? separatorWidth : 0)
        // 接在行尾会越过右边界、且这一行已经有东西时另起一行；行首不留间距，段分隔也不画在行首。
        // 单项比整行还宽时仍独占一行，多出来的部分靠横向滚动看。
        if wraps, x > inset, x + leading + viewWidth > clipSize.width - trailing {
          line += 1
          x = inset
          leading = 0
        }
        if index == 0, leading > 0 { separators.append((x + separatorGap, line)) }
        x += leading
        let height = view is NSProgressIndicator ? spinnerSide : buttonHeight
        view.frame = NSRect(
          x: x, y: CGFloat(line) * lineHeight + (lineHeight - height) / 2, width: viewWidth, height: height)
        view.isHidden = false
        x += viewWidth
        maxX = max(maxX, x)
      }
    }
    let contentHeight = wraps ? CGFloat(line + 1) * lineHeight : clipSize.height
    contentView.frame = NSRect(
      x: 0, y: 0, width: max(clipSize.width, maxX + trailing), height: max(clipSize.height, contentHeight))
    scrollView.convertsVerticalWheel = !wraps
    // 内容变短后把滚动位置夹回有效范围（刷新时保留原位置，只在越界时收回）。
    scrollView.reflectScrolledClipView(scrollView.contentView)
    layoutSeparators(separators, lineHeight: lineHeight, buttonHeight: buttonHeight)
  }

  /// 每段要排的视图：按钮，加上到时的 spinner。没到时的 spinner 停下并隐藏。
  private func layoutPlan() -> [[NSView]] {
    var plan: [[NSView]] = []
    for group in groups where !group.buttons.isEmpty {
      var views: [NSView] = group.buttons
      let spinner = spinners[group.segment.id]
      if showsSpinner(group.segment) {
        let spinner = self.spinner(for: group.segment.id)
        views.append(spinner)
        spinner.startAnimation(nil)
      } else {
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
      }
      plan.append(views)
    }
    return plan
  }

  /// 把手贴在对应边上，盖在内容上面。
  private func layoutResizeHandle() {
    guard let resizeHandle else { return }
    let thickness = Self.resizeHandleThickness
    let y = resizeHandle.edge == .top ? bounds.height - thickness : 0
    resizeHandle.frame = NSRect(x: 0, y: y, width: bounds.width, height: min(thickness, bounds.height))
  }

  /// 段间分隔线（在内容层里，跟着内容滚动）与边线。`tab.bottom` 的边线在顶部（贴着终端），`tab.top` 在底部。
  private func layoutSeparators(_ separators: [(x: CGFloat, line: Int)], lineHeight: CGFloat, buttonHeight: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // 条在上方（tab.top、window.top）时边线画在底部，贴着下面的内容；其余画在顶部。
    let lineY: CGFloat = slot == .tabTop || slot == .windowTop ? 0 : bounds.height - 1
    edgeLine.frame = NSRect(x: 0, y: lineY, width: bounds.width, height: 1)
    CATransaction.commit()
    while separatorViews.count < separators.count {
      let view = NSView()
      view.wantsLayer = true
      contentView.addSubview(view)
      separatorViews.append(view)
    }
    let separatorHeight = round(buttonHeight * 0.6)
    for (index, view) in separatorViews.enumerated() {
      view.isHidden = index >= separators.count
      guard index < separators.count else { continue }
      let separator = separators[index]
      view.frame = NSRect(
        x: separator.x, y: CGFloat(separator.line) * lineHeight + (lineHeight - separatorHeight) / 2, width: 1,
        height: separatorHeight)
    }
    needsDisplay = true
  }

  override var wantsUpdateLayer: Bool { true }

  /// tab.* 条背景透明，只画边线与分隔线；颜色按当前外观解析。悬停 / 拖动把手时边线换成强调色。
  override func updateLayer() {
    layer?.backgroundColor = NSColor.clear.cgColor
    let palette = ToolBarPalette.resolve(theme: themeProvider?())
    var border = NSColor.clear.cgColor
    var edge = NSColor.clear.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      border = palette.border.cgColor
      edge = (isEdgeHighlighted ? palette.accent : palette.border).cgColor
    }
    edgeLine.backgroundColor = edge
    separatorViews.forEach { $0.layer?.backgroundColor = border }
  }

  // MARK: - 拖动窗口

  override var mouseDownCanMoveWindow: Bool { isWindowDragRegion }

  /// 空白处：单击拖动窗口，双击与系统标题栏一样缩放（同 `WorkspaceTitleBarBackgroundView`）。按钮自己先吃掉命中。
  override func mouseDown(with event: NSEvent) {
    guard isWindowDragRegion, let window else { return super.mouseDown(with: event) }
    if event.clickCount == 2 {
      window.performZoom(nil)
    } else {
      window.performDrag(with: event)
    }
  }

  /// 当前排在条上的按钮（测试用）。
  var visibleButtons: [ToolBarItemButton] {
    groups.flatMap(\.buttons).filter { !$0.isHidden }
  }
}
