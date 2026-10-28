// 界面扩展的原生横条：同一挂载点的所有 bar 视图共用一条，每个视图一段，段间 1pt 竖分隔。
// 由 WorkspaceExtensionHost 长期持有，工作区整树重建时只换父视图；内容变化只调 `apply(segments:)`。
// 放不下的项目收进末尾「…」菜单；全部为空时整条隐藏且高度归零，不在终端下面留空白。
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

  let slot: ToolViewSlot
  /// 点了带动作的项目（段 id、项目）。
  var onItem: ((_ segmentID: String, _ item: ToolBarItem) -> Void)?
  /// 点了失败段：重跑。
  var onRetry: ((_ segmentID: String) -> Void)?
  /// 点了「需要授权」。
  var onApprove: ((_ segmentID: String) -> Void)?
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
  private let overflowButton = ToolBarItemButton()
  /// 这次布局放不下、进了「…」菜单的按钮。
  private(set) var overflowedButtons: [ToolBarItemButton] = []
  private let edgeLine = CALayer()
  private var separatorLayers: [CALayer] = []
  private var heightConstraint: NSLayoutConstraint!
  private var barHeight: CGFloat
  private var spinnerWork: DispatchWorkItem?

  /// `height` 是清单里的条高（点，未缩放）。
  init(slot: ToolViewSlot, height: Int) {
    self.slot = slot
    barHeight = Self.scaledHeight(height, slot: slot)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("tool-bar-\(slot.rawValue)")
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    layer?.addSublayer(edgeLine)
    overflowButton.configure(.overflow)
    overflowButton.onPress = { [weak self] in self?.showOverflowMenu() }
    addSubview(overflowButton)
    heightConstraint = heightAnchor.constraint(equalToConstant: barHeight)
    heightConstraint.isActive = true
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel(L("插件状态条"))
    isHidden = true
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 换条高（清单变化）。
  func setHeight(_ height: Int) {
    barHeight = Self.scaledHeight(height, slot: slot)
    heightConstraint.constant = isHidden ? 0 : barHeight
  }

  /// 条高随界面字号缩放；window.top 与红绿灯同一行，几何由窗口决定，不缩放。
  private static func scaledHeight(_ height: Int, slot: ToolViewSlot) -> CGFloat {
    slot == .windowTop ? CGFloat(height) : InterfaceScale.length(CGFloat(height))
  }

  /// 隐藏时高度归零：插入点的约束链是必需约束，隐藏视图仍参与布局，不归零会在终端下留一条空白。
  override var isHidden: Bool {
    didSet { heightConstraint?.constant = isHidden ? 0 : barHeight }
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

  /// 一段要显示的按钮内容与复用键。
  private static func contents(of segment: ToolBarSegment) -> [(String, ToolBarItemButton.Content)] {
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
    case .overflow: return nil
    }
  }

  /// 新按钮挂进视图树，配色跟当前主题。
  private func makeButton() -> ToolBarItemButton {
    let button = ToolBarItemButton()
    addSubview(button)
    return button
  }

  /// 主题或外观变了：重新解析颜色并推给每个按钮。
  func refreshAppearance() {
    let palette = ToolBarPalette.resolve(theme: themeProvider?())
    for button in buttons.values { button.palette = palette }
    overflowButton.palette = palette
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
    addSubview(spinner)
    spinners[segmentID] = spinner
    return spinner
  }

  // MARK: - 布局

  /// 手工排版：左内边距 8，项目间距 2，段间 6 + 1pt 分隔 + 6。总宽放不下时末尾留「…」，
  /// 从第一个放不下的项目起全部收进菜单（不跳着塞，顺序与脚本输出一致）。
  override func layout() {
    super.layout()
    let inset = leadingInset ?? InterfaceScale.length(8)
    let spacing = InterfaceScale.length(2)
    let separatorGap = InterfaceScale.length(6)
    let buttonHeight = max(0, min(bounds.height - InterfaceScale.length(4), InterfaceScale.length(22)))
    let spinnerSide = InterfaceScale.length(10)
    let y = (bounds.height - buttonHeight) / 2

    // 每段要排的视图：按钮，加上到时的 spinner。
    var plan: [(segmentID: String, views: [NSView])] = []
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
      plan.append((group.segment.id, views))
    }
    func width(of view: NSView) -> CGFloat {
      view is NSProgressIndicator ? spinnerSide : ceil(view.intrinsicContentSize.width)
    }
    let separatorWidth = separatorGap * 2 + 1
    let viewWidths = plan.flatMap(\.views).map(width)
    let total =
      viewWidths.reduce(0, +) + CGFloat(max(0, viewWidths.count - plan.count)) * spacing
      + CGFloat(max(0, plan.count - 1)) * separatorWidth
    let available = max(0, bounds.width - inset - InterfaceScale.length(8))
    let overflowWidth = ceil(overflowButton.intrinsicContentSize.width)
    let limit = total <= available ? available : max(0, available - overflowWidth - spacing)

    var x = inset
    var separators: [CGFloat] = []
    var overflowing = total > available
    var didOverflow = false
    overflowedButtons = []
    // 已经排上过任何视图：之后每段的第一个视图前要留分隔。
    var placedEarlierSegment = false
    for entry in plan {
      var placedAny = false
      for view in entry.views {
        let viewWidth = width(of: view)
        let leading = placedAny ? spacing : (placedEarlierSegment ? separatorWidth : 0)
        if didOverflow || (overflowing && x + leading + viewWidth > inset + limit) {
          didOverflow = true
          view.isHidden = true
          if let button = view as? ToolBarItemButton { overflowedButtons.append(button) }
          continue
        }
        if !placedAny, leading > 0 { separators.append(x + separatorGap) }
        x += leading
        let height = view is NSProgressIndicator ? spinnerSide : buttonHeight
        view.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: viewWidth, height: height)
        view.isHidden = false
        x += viewWidth
        placedAny = true
      }
      if placedAny { placedEarlierSegment = true }
    }
    overflowing = !overflowedButtons.isEmpty
    overflowButton.isHidden = !overflowing
    if overflowing {
      overflowButton.frame = NSRect(x: x + spacing, y: y, width: overflowWidth, height: buttonHeight)
    }
    layoutLayers(separators: separators, buttonHeight: buttonHeight)
  }

  /// 边线与段间分隔线。`tab.bottom` 的边线在顶部（贴着终端），`tab.top` 在底部。
  private func layoutLayers(separators: [CGFloat], buttonHeight: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // 条在上方（tab.top、window.top）时边线画在底部，贴着下面的内容；其余画在顶部。
    let lineY: CGFloat = slot == .tabTop || slot == .windowTop ? 0 : bounds.height - 1
    edgeLine.frame = NSRect(x: 0, y: lineY, width: bounds.width, height: 1)
    while separatorLayers.count < separators.count {
      let layer = CALayer()
      self.layer?.addSublayer(layer)
      separatorLayers.append(layer)
    }
    let separatorHeight = round(buttonHeight * 0.6)
    for (index, layer) in separatorLayers.enumerated() {
      layer.isHidden = index >= separators.count
      guard index < separators.count else { continue }
      layer.frame = NSRect(
        x: separators[index], y: (bounds.height - separatorHeight) / 2, width: 1, height: separatorHeight)
    }
    CATransaction.commit()
    needsDisplay = true
  }

  override var wantsUpdateLayer: Bool { true }

  /// tab.* 条背景透明，只画边线与分隔线；颜色按当前外观解析。
  override func updateLayer() {
    layer?.backgroundColor = NSColor.clear.cgColor
    let border = ToolBarPalette.resolve(theme: themeProvider?()).border
    var resolved = NSColor.clear.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { resolved = border.cgColor }
    edgeLine.backgroundColor = resolved
    separatorLayers.forEach { $0.backgroundColor = resolved }
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

  // MARK: - 溢出菜单

  /// 收进「…」的项目做成菜单；选中等同点击。
  func makeOverflowMenu() -> NSMenu {
    let menu = NSMenu()
    for button in overflowedButtons {
      let item = ActionMenuItem(title: button.menuTitle) { [weak button] in button?.onPress?() }
      item.image = button.menuImage
      item.toolTip = button.toolTip
      item.isEnabled = button.onPress != nil
      menu.addItem(item)
    }
    menu.autoenablesItems = false
    return menu
  }

  /// 在「…」下方弹出菜单。
  private func showOverflowMenu() {
    makeOverflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: overflowButton)
  }

  /// 「…」是否可见（测试用）。
  var isOverflowVisible: Bool { !overflowButton.isHidden }

  /// 当前排在条上的按钮（测试用）。
  var visibleButtons: [ToolBarItemButton] {
    groups.flatMap(\.buttons).filter { !$0.isHidden }
  }
}
