// 工具面板（启动器 B）的窗口策略与工具会话宿主。非激活浮动面板（参照 Quick Terminal），出现在鼠标所在
// 屏幕的上三分之一处，宽 720；失去 key 自动隐藏，并把焦点还给之前的应用。钉住后不再自动收起、在所有桌面
// 空间显示；拖动搜索行或底栏可移动面板，之后呼出都放在拖到的位置。全局快捷键、「窗口 → 工具面板」、
// 命令面板与 `asterShowToolLauncher` 通知都从这里呼出。面板内容在 ToolLauncherViewController。
import AppKit
import AsterCore

/// 工具面板控制器。只在主线程使用。
@MainActor
final class ToolLauncherController: NSObject, NSWindowDelegate {
  static let panelWidth: CGFloat = 720

  private let preferences: AppPreferences
  private let hotKey = ToolLauncherHotKey()
  /// 解析这次呼出的目标工作区：有来源 Pane 时取它所在的窗口，否则取当前或最前的工作区窗口。
  private let workspaceModelProvider: (ToolTerminalOrigin?) -> AppModel?
  private var panel: ToolLauncherPanel?
  private var content: ToolLauncherViewController?
  private(set) var isPresented = false
  private var previousApplication: NSRunningApplication?
  private var reportedShortcutFailure: String?
  private var animationGeneration = 0
  /// 面板顶边。呼出时按屏幕算一次，之后内容变高只往下长，搜索框不跳。
  private var anchorTop: CGFloat = 0
  /// 面板左边。没拖过时为 nil，按屏幕水平居中。
  private var anchorLeft: CGFloat?
  /// 用户拖到的位置（左上角，屏幕坐标）。之后每次呼出都放在这里，不再按鼠标所在屏幕居中；只在本次运行内记住。
  private var placement: NSPoint?
  /// 钉住：失去 key 不收起、在所有桌面空间显示，把用户带回工作区的动作也不收起面板。收起后再呼出仍保持钉住；
  /// 只在本次运行内记住。
  private(set) var isPinned = false
  /// 控制器自己正在把面板设为 key。这期间的 didBecomeKey 不改来源：来源已经按这次呼出或请求定好。
  private var isMakingPanelKey = false
  /// 本次呼出的目标工作区与来源 Pane。`⌘↩` 与 `terminal.insert` 只写这个来源。
  private weak var targetModel: AppModel?
  private var origin: ToolTerminalOrigin?
  /// 正在使用的工具。
  private var session: ToolSessionViewController?

  /// 面板当前是否是 key window（菜单校验用）。
  var ownsKeyWindow: Bool { panel?.isKeyWindow == true }

  /// 创建控制器并接上热键回调；面板在第一次呼出时才建。
  init(
    preferences: AppPreferences,
    workspaceModelProvider: @escaping (ToolTerminalOrigin?) -> AppModel?
  ) {
    self.preferences = preferences
    self.workspaceModelProvider = workspaceModelProvider
    super.init()
    hotKey.onPress = { [weak self] in self?.toggle() }
  }

  // MARK: - 快捷键与设置

  /// 启动与设置变化时调用：按 `tools.launcherShortcut` 注册全局快捷键。注册失败只提示一次，
  /// 用户仍可经「窗口 → 工具面板」与命令面板打开。
  func refresh() {
    let value = preferences.compatibilityString(
      forKey: ToolLauncherShortcut.settingKey, default: ToolLauncherShortcut.defaultValue.rawValue)
    let status = hotKey.configure(settingValue: value)
    if status != noErr, reportedShortcutFailure != value {
      reportedShortcutFailure = value
      let alert = NSAlert()
      alert.messageText = L("工具面板快捷键无法注册")
      alert.informativeText = L("快捷键可能已被 Quick Terminal 或其他应用占用。请在设置中更换；仍可通过“窗口 → 工具面板”打开。")
      alert.runModal()
    } else if status == noErr {
      reportedShortcutFailure = nil
    }
    panel?.appearance = preferences.preferredAppearance
  }

  /// 全局快捷键：开着就收起，否则呼出空面板；钉住的面板没拿着键盘时改为把它叫到前面。应用正处在模态会话
  /// （例如工具弹的确认框）时不动，免得把会话拆在模态循环底下。
  func toggle() {
    guard NSApp.modalWindow == nil else { return }
    if !isPresented {
      show(request: nil)
    } else if isPinned, let panel, !panel.isKeyWindow, panel.attachedSheet == nil {
      bringToFront()
    } else {
      hide()
    }
  }

  /// 切换钉住。钉住与否只改收起策略与桌面空间行为，面板位置不动。
  func setPinned(_ pinned: Bool) {
    isPinned = pinned
    content?.isPinned = pinned
    applyCollectionBehavior()
  }

  /// 钉住的面板跟着用户出现在每个桌面空间；没钉住时跟随呼出时的活动空间。
  private func applyCollectionBehavior() {
    panel?.collectionBehavior =
      isPinned
      ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
  }

  // MARK: - 呼出与收起

  /// 呼出面板。带请求时直接打开该工具（来源用请求里的）；不带请求时来源取目标工作区的活动 Pane。
  func show(request: ToolLaunchRequest?) {
    if !isPresented {
      present(origin: request?.origin)
    } else {
      if let request {
        // 面板开着时又来了请求（例如从工作区窗口发出）：来源以新请求为准。
        targetModel = workspaceModelProvider(request.origin)
        origin = request.origin
      }
      // 钉住的面板可能正停在背后没拿着键盘。
      bringToFront()
    }
    guard let request else { return }
    openTool(entry: request.entry, input: request.input, queryText: request.input.text ?? "")
  }

  /// 呼出空面板（拖过就放在拖到的位置，否则在鼠标所在屏幕居中）：记下之前的应用与来源 Pane，重置内容后淡入。
  private func present(origin requestedOrigin: ToolTerminalOrigin?) {
    rememberPreviousApplication()
    let context = resolveTarget(requestedOrigin)
    let (panel, content) = ensurePanel()
    let visible = presentationVisibleFrame()
    content.maximumContentHeight = visible.height - 40
    content.reset(context: context)
    anchorTop = placement?.y ?? Self.anchorTop(in: visible)
    anchorLeft = placement?.x
    panel.appearance = preferences.preferredAppearance
    panel.setFrame(
      Self.frame(contentHeight: content.preferredContentHeight, top: anchorTop, left: anchorLeft, in: visible),
      display: false)
    isPresented = true
    animationGeneration += 1
    panel.alphaValue = 0
    makeKey(panel)
    panel.invalidateShadow()
    content.didPresent()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animationDuration
      panel.animator().alphaValue = 1
    }
  }

  /// 记下 Aster 之外的前台应用，Esc 收起面板时把焦点还给它。非激活面板拿到键盘时前台应用不变。
  private func rememberPreviousApplication() {
    if let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApplication = app
    } else {
      previousApplication = nil
    }
  }

  /// 定下目标工作区与来源 Pane（没给来源时取目标工作区的活动 Pane），返回来源的工具环境。
  private func resolveTarget(_ requestedOrigin: ToolTerminalOrigin?) -> ToolContext {
    let model = workspaceModelProvider(requestedOrigin)
    targetModel = model
    origin = requestedOrigin ?? model?.toolTerminalOrigin()
    return model?.toolContext(for: origin)
      ?? ToolCenter.shared.makeContext(workingDirectory: nil, isRemote: false)
  }

  /// 呼出时所在屏幕的可见区域：拖到的位置还落在某块屏幕上就用那块屏幕（显示器拔掉后忘掉这个位置），
  /// 否则取鼠标所在的屏幕。
  private func presentationVisibleFrame() -> NSRect {
    if let placement {
      // 左上角可能正好贴在可见区域的上边或左边，`contains` 不含上边，放宽 1pt。
      if let screen = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(placement) }) {
        return screen.visibleFrame
      }
      self.placement = nil
    }
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  }

  /// 把开着却没拿着键盘的面板叫到前面，键盘交给搜索框。
  private func bringToFront() {
    guard isPresented, let panel, !panel.isKeyWindow, panel.attachedSheet == nil else { return }
    makeKey(panel)
    content?.focusSearchField()
  }

  /// 由控制器把面板设为 key 并提到前面；见 `isMakingPanelKey`。
  private func makeKey(_ panel: NSPanel) {
    isMakingPanelKey = true
    defer { isMakingPanelKey = false }
    panel.makeKeyAndOrderFront(nil)
  }

  /// 用户拖完面板：记下新位置，之后内容变高从这里往下长，下次呼出也放在这里。
  private func panelDidDrag() {
    guard let panel else { return }
    anchorTop = panel.frame.maxY
    anchorLeft = panel.frame.minX
    placement = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    if let visible = panel.screen?.visibleFrame { content?.maximumContentHeight = visible.height - 40 }
  }

  /// 收起面板并结束正在使用的工具。`restoreFocus` 为 true 时把焦点还给呼出前的应用；
  /// 因为点了别处而失去 key、或要把用户带回工作区时传 false。
  func hide(restoreFocus: Bool = true) {
    guard isPresented, let panel else { return }
    isPresented = false
    content?.didDismiss()
    // 挂在面板上的确认框、文件选择框按「取消」结束，工具不会一直等一个看不见的 sheet。
    // 遍历的是此刻的快照：回调里若又挂了新的 sheet，也不会在这里无限循环。
    for sheet in panel.sheets.reversed() { panel.endSheet(sheet, returnCode: .cancel) }
    teardownSession()
    animationGeneration += 1
    let generation = animationGeneration
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animationDuration
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.animationGeneration == generation, !self.isPresented else { return }
        panel.orderOut(nil)
        if restoreFocus { self.previousApplication?.activate(options: []) }
        self.previousApplication = nil
      }
    }
  }

  /// 应用退出：释放热键、结束工具、销毁面板。
  func shutdown() {
    hotKey.stop()
    teardownSession()
    content?.didDismiss()
    animationGeneration += 1
    isPresented = false
    panel?.orderOut(nil)
    panel = nil
    content = nil
    previousApplication = nil
  }

  private var animationDuration: Double {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
  }

  /// 面板与内容只建一次，之后反复显示、隐藏。
  private func ensurePanel() -> (ToolLauncherPanel, ToolLauncherViewController) {
    if let panel, let content { return (panel, content) }
    // 无边框 + 非激活：呼出时不激活 Aster，焦点还在别的应用里时也能直接输入；圆角与阴影由内容视图提供。
    let panel = ToolLauncherPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Aster Tools"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    panel.delegate = self
    panel.onCancel = { [weak self] in self?.handleCancel() }
    panel.onDidDrag = { [weak self] in self?.panelDidDrag() }
    let content = ToolLauncherViewController()
    content.delegate = self
    content.isPinned = isPinned
    panel.contentView = content.view
    panel.isDragHandle = { [weak content] view in content?.isDragHandle(view) == true }
    self.panel = panel
    self.content = content
    applyCollectionBehavior()
    return (panel, content)
  }

  /// 面板顶边：可见区域自上而下六分之一处，搜索框落在屏幕上三分之一里。
  static func anchorTop(in visible: NSRect) -> CGFloat {
    visible.maxY - visible.height / 6
  }

  /// 按内容高度算面板位置：宽 720，顶边贴 `top` 往下长；下面放不下时整体上移，仍放不下就压缩到可见区域内
  /// （上下各留 20pt）。`left` 是拖动后的左边，没给就水平居中；给了也收进可见区域，面板不会跑出屏幕。
  static func frame(contentHeight: CGFloat, top: CGFloat, left: CGFloat? = nil, in visible: NSRect) -> NSRect {
    let width = min(panelWidth, max(visible.width - 40, 320))
    let height = min(max(contentHeight, 1), max(visible.height - 40, 1))
    let resolvedTop = min(top, visible.maxY)
    let originY = max(resolvedTop - height, visible.minY + 20)
    let originX = left.map { min(max($0, visible.minX), visible.maxX - width) } ?? visible.midX - width / 2
    return NSRect(x: originX, y: originY, width: width, height: height)
  }

  /// 内容高度变化后调整面板，顶边不动。
  private func applyContentHeight(animated: Bool) {
    guard isPresented, let panel, let content else { return }
    let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
    let target = Self.frame(
      contentHeight: content.preferredContentHeight, top: anchorTop, left: anchorLeft, in: visible)
    guard target != panel.frame else { return }
    guard animated, animationDuration > 0 else {
      panel.setFrame(target, display: true)
      panel.invalidateShadow()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.allowsImplicitAnimation = true
      panel.animator().setFrame(target, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { panel.invalidateShadow() }
    }
  }

  // MARK: - 工具

  /// 打开工具：结束上一个工具，按这次的来源建会话，展开在结果列表的位置。
  private func openTool(entry: ToolCatalogEntry, input: ToolInput, queryText: String) {
    teardownSession()
    let request = ToolLaunchRequest(entry: entry, input: input, origin: origin)
    let session = ToolCenter.shared.makeSession(for: request, host: self)
    self.session = session
    ToolCenter.shared.recordUse(entryID: entry.id)
    content?.presentTool(session, title: entry.feature.title, queryText: queryText)
    applyContentHeight(animated: true)
  }

  /// 结束正在使用的工具。会话移出视图树前必须先 `teardown()`。
  private func teardownSession() {
    guard let session else { return }
    self.session = nil
    session.teardown()
  }

  /// 退出工具，回到结果列表。
  private func exitTool() {
    teardownSession()
    content?.dismissTool()
    applyContentHeight(animated: true)
  }

  /// 面板收到 `cancelOperation`（键盘监视没接住的 Esc）：先退工具，再关面板。
  private func handleCancel() {
    if session != nil { exitTool() } else { hide() }
  }

  /// 把文字预填到来源 Pane：先收起面板、把工作区窗口与来源 Pane 带到前台，下一轮再写入——
  /// 终端成为 first responder 之后，粘贴保护等界面才挂在正确的视图上。
  private func prefillOrigin(with text: String) {
    guard let origin, origin.isAlive else {
      content?.showNotice(L("没有可以预填的终端：请先在工作区里选中一个终端 Pane"), isError: true)
      return
    }
    let model = targetModel
    stepAsideForWorkspace()
    revealWorkspace(model, paneID: origin.paneID)
    DispatchQueue.main.async { [weak model] in
      if let failure = origin.insert(text) { model?.notice = failure }
    }
  }

  /// 要把用户带去工作区：没钉住就收起面板（不抢回焦点）；钉住的面板留在原处。
  private func stepAsideForWorkspace() {
    if !isPinned { hide(restoreFocus: false) }
  }

  /// 把工具开成目标工作区的 Pane，然后收起面板（钉住时只退出工具，免得同一个工具开两份）、带用户回到工作区。
  private func openAsPane(entry: ToolCatalogEntry, input: ToolInput) {
    guard let model = targetModel else {
      content?.showNotice(L("没有打开的工作区窗口"), isError: true)
      return
    }
    guard model.openToolPane(entryID: entry.id, input: input, origin: origin) else {
      content?.showNotice(model.notice ?? L("无法开成 Pane"), isError: true)
      return
    }
    if isPinned {
      if session != nil { exitTool() }
    } else {
      hide(restoreFocus: false)
    }
    revealWorkspace(model, paneID: nil)
  }

  /// 激活 Aster 并把工作区窗口提到前面；给了 Pane 就同时切到它所在的标签并聚焦。
  private func revealWorkspace(_ model: AppModel?, paneID: UUID?) {
    NSApp.activate()
    model?.onRequestWindowFocus?()
    guard let model, let paneID,
      let tab = model.tabs.first(where: { $0.layout.descriptor(forPane: paneID) != nil })
    else { return }
    model.revealWorkspaceLocation(tabID: tab.id, paneID: paneID)
  }

  // MARK: - NSWindowDelegate

  /// 失去 key 自动隐藏（不抢回焦点：用户已经点去了别处）；钉住时不收起。网页工具与运行时的确认框、
  /// 文件选择框以 sheet 挂在面板上，弹出时面板也会失去 key，这些时候不能收起；判断放到下一轮，模态会话与
  /// sheet 那时已经建立。
  func windowDidResignKey(_ notification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isPresented, !self.isPinned, let panel = self.panel, !panel.isKeyWindow,
        panel.attachedSheet == nil, NSApp.keyWindow?.sheetParent !== panel, NSApp.modalWindow == nil
      else { return }
      self.hide(restoreFocus: false)
    }
  }

  /// 钉住的面板在背后停了一阵又拿到键盘：前台应用与活动 Pane 可能都换了。重新记下前台应用（Esc 收起后
  /// 焦点还给它）；没开工具时来源换成当前活动 Pane，预填与匹配环境都跟着它。开着工具时来源跟工具会话走，不动。
  func windowDidBecomeKey(_ notification: Notification) {
    guard isPresented, isPinned, !isMakingPanelKey else { return }
    rememberPreviousApplication()
    guard session == nil else { return }
    content?.updateContext(resolveTarget(nil))
  }

  /// 挂在面板上的 sheet 关掉后把键盘还给面板，用户可以接着输入。
  func windowDidEndSheet(_ notification: Notification) {
    guard isPresented, let panel, panel.attachedSheet == nil else { return }
    makeKey(panel)
  }

  /// 搜索框用专用的 field editor（拖到搜索框上的文件按文件输入处理）；其它控件用系统默认的。
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    content?.fieldEditor(for: client)
  }
}

// MARK: - 内容区意图

extension ToolLauncherController: ToolLauncherContentDelegate {
  /// 打开选中的一行。
  func launcherContent(
    _ content: ToolLauncherViewController, open row: ToolLauncherRow, input: ToolInput, queryText: String
  ) {
    openTool(entry: row.entry, input: input, queryText: queryText)
  }

  /// 工具打开时预填工具的结果，否则预填选中行的行内结果。
  func launcherContentDidRequestPrefill(_ content: ToolLauncherViewController) {
    // 工具开着时只认工具自己的结果；没有工具时才用选中行的行内结果。
    let text: String?
    if let session {
      text = session.primaryResultText
    } else {
      text = content.selectedRow?.inlineResult
    }
    guard let text, !text.isEmpty else {
      content.showNotice(L("没有可以预填的结果"), isError: true)
      return
    }
    if let entryID = session?.request.entry.id ?? content.selectedRow?.entry.id {
      ToolCenter.shared.recordUse(entryID: entryID)
    }
    prefillOrigin(with: text)
  }

  /// 工具打开时把当前工具（带当前输入）开成 Pane，否则开选中行。
  func launcherContentDidRequestOpenAsPane(_ content: ToolLauncherViewController) {
    if let session {
      openAsPane(entry: session.request.entry, input: session.request.input)
    } else if let row = content.selectedRow {
      openAsPane(entry: row.entry, input: content.launchInput(for: row))
    }
  }

  /// 搜索框里的新文字交给正在使用的工具。
  func launcherContent(_ content: ToolLauncherViewController, toolQueryChanged text: String) {
    session?.updateQuery(text)
  }

  /// 工具打开时拖进来的文件作为新输入交给它。
  func launcherContent(_ content: ToolLauncherViewController, toolReceivedFiles files: [String]) {
    guard let session else { return }
    session.deliver(input: ToolInput(files: files, source: .file, context: session.request.input.context))
  }

  /// 工具打开时的 Esc：退出工具，回到结果列表。
  func launcherContentDidRequestExitTool(_ content: ToolLauncherViewController) { exitTool() }

  /// 没有工具时的 Esc：收起面板并把焦点还给之前的应用。
  func launcherContentDidRequestClose(_ content: ToolLauncherViewController) { hide() }

  /// 点了图钉：切换钉住。
  func launcherContentDidTogglePin(_ content: ToolLauncherViewController) { setPinned(!isPinned) }

  /// 内容高度变了，调整面板，顶边不动。
  func launcherContentDidChangeHeight(_ content: ToolLauncherViewController, animated: Bool) {
    applyContentHeight(animated: animated)
  }
}

// MARK: - ToolSessionHost

extension ToolLauncherController: ToolSessionHost {
  /// 工具请求关闭：回到结果列表而不是收起面板，`none` 脚本的「已完成」提示才看得见。请求可能发自工具
  /// 自己的回调栈，延后一轮再拆。
  func toolSessionDidRequestClose(_ session: ToolSessionViewController) {
    DispatchQueue.main.async { [weak self, weak session] in
      guard let self, let session, self.session === session else { return }
      self.exitTool()
    }
  }

  /// 只接受当前工具的高度请求。
  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat) {
    guard self.session === session else { return }
    content?.setToolHeight(height)
  }

  /// 工具的提示显示在面板底栏。
  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool) {
    content?.showNotice(text, isError: isError)
  }

  /// 工具桥接的 `terminal.insert`：只写本次来源，面板保持打开，由工具决定接下来做什么。
  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool {
    guard let origin = session.request.origin else {
      content?.showNotice(L("没有来源终端：请从终端 Pane 呼出工具面板"), isError: true)
      return false
    }
    if let failure = origin.insert(text) {
      content?.showNotice(failure, isError: true)
      return false
    }
    return true
  }

  /// 工具要求改到工作区 Pane 里打开。
  func toolSessionOpenInPane(_ session: ToolSessionViewController) {
    openAsPane(entry: session.request.entry, input: session.request.input)
  }

  /// 在目标工作区的新标签里运行命令，然后带用户过去看输出。
  func toolSession(
    _ session: ToolSessionViewController,
    runInTerminal command: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) {
    guard let model = targetModel else {
      content?.showNotice(L("没有打开的工作区窗口"), isError: true)
      return
    }
    model.runToolCommandInNewTab(command, workingDirectory: workingDirectory, environment: environment)
    stepAsideForWorkspace()
    revealWorkspace(model, paneID: nil)
  }

  var toolSessionWindow: NSWindow? { panel }
}
