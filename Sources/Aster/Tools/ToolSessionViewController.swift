// 一次打开的工具的展示控制器：按功能动作分派到原生内置工具、脚本输出或网页工具；插件需要确认时先显示授权提示。
// 只经 `ToolCenter.makeSession(for:host:)` 创建；容器移除视图前必须调用 `teardown()`。
import AppKit
import AsterCore

/// 承载一个正在使用的工具：原生内置工具视图、脚本输出或网页工具。
@MainActor
final class ToolSessionViewController: NSViewController, ToolWebHost {
  /// 当前请求（输入会随 `updateQuery` / `deliver` 更新）。
  private(set) var request: ToolLaunchRequest
  weak var host: ToolSessionHost?

  /// 当前显示的内容。
  private enum Content {
    case empty
    /// 提示（找不到、已停用、出错、运行中）；`status` 是显示时的插件状态，状态变了才重新判断。
    case message(NSView, status: ToolPluginStatus?)
    case approval(ToolApprovalPromptView, status: ToolPluginStatus)
    case builtin(any BuiltinToolContent)
    case script(ScriptToolController)
    case web(WebToolViewController)
  }

  private let center: ToolCenter
  private let rootView = ToolSessionRootView()
  private var content: Content = .empty
  /// 每次重新判断状态加一；异步结果只认发起时的代次。
  private var startGeneration = 0
  private var isTornDown = false
  /// 网页工具经 `ui.setHeight` 请求的高度。
  private var webHeight: CGFloat?

  init(request: ToolLaunchRequest, host: ToolSessionHost, center: ToolCenter) {
    self.request = request
    self.host = host
    self.center = center
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    rootView.onAppearanceChange = { [weak self] in
      guard let self, case .web(let web) = self.content else { return }
      web.applyAppearance(self.rootView.appearanceName)
    }
    view = rootView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    start()
  }

  // MARK: 对容器的接口

  /// 工具希望的内容高度（点）。
  var preferredHeight: CGFloat {
    switch content {
    case .empty: 200
    case .message: 180
    case .approval: 260
    case .builtin(let tool): tool.preferredHeight
    case .script(let script): script.preferredHeight
    case .web(let web): webHeight ?? CGFloat(web.plugin.manifest.resolvedUIHeight)
    }
  }

  /// 当前可复制或预填的结果文本（脚本 text 输出、内置转换结果、列表选中项）；没有则 nil。
  var primaryResultText: String? {
    switch content {
    case .builtin(let tool): tool.primaryResultText
    case .script(let script): script.primaryResultText
    case .empty, .message, .approval, .web: nil
    }
  }

  /// 启动器搜索框在工具打开后继续输入：内置转换实时更新，list 脚本去抖重跑，网页工具收到 `query` 事件。
  func updateQuery(_ text: String) {
    request.input.text = text
    switch content {
    case .builtin(let tool): tool.update(input: request.input)
    case .script(let script): script.updateQuery(request.input)
    case .web(let web): web.updateQuery(text)
    case .empty, .message, .approval: break
    }
  }

  /// 换一份新输入重新进入（同一工具再次被打开时复用控制器）。panel 视图不重新进入，只推送新上下文。
  func deliver(input: ToolInput) {
    request.input = input
    switch content {
    case .builtin(let tool): tool.update(input: input)
    case .script(let script): script.rerun(with: input)
    case .web(let web) where request.view != nil: web.updateContext(input, extended: request.extendedContext)
    case .web(let web): web.deliver(input: input)
    case .approval: break  // 授权后用最新输入运行
    case .message: start()
    case .empty: if isViewLoaded { start() }  // 视图还没加载时由 viewDidLoad 用最新输入启动
    }
  }

  /// panel 视图换上下文（切标签、切 Pane、cd）：更新输入、来源终端与扩展上下文。
  /// 网页已经在运行时页面收到 `context` 事件、不重新进入；其余状态（授权提示、提示）照 `deliver` 处理。
  func updateContext(input: ToolInput, origin: ToolTerminalOrigin?, extendedContext: [String: JSONValue]) {
    request.origin = origin
    request.extendedContext = extendedContext
    deliver(input: input)
  }

  /// 释放资源：取消脚本、关闭 WebView。容器移除视图前必须调用。
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    startGeneration += 1
    replaceContent(.empty)
    center.sessionDidTearDown(self)
  }

  // MARK: 工具中心的通知

  /// 插件列表、启用或授权变化后调用：授权完成就开始运行；网页工具不再可运行就撤下，清单变了就重建。
  func pluginStateDidChange() {
    guard !isTornDown else { return }
    let pluginID = request.entry.pluginID
    let status = center.pluginStatus(pluginID: pluginID)
    switch content {
    case .approval(_, let shown) where status != shown:
      start()
    case .message(_, let shown) where status != shown:
      start()
    case .web(let web):
      guard status == .ready, let info = center.runtimeInfo(pluginID: pluginID) else {
        start()
        return
      }
      if info.manifest != web.plugin.manifest || info.directory != web.plugin.directory
        || info.grantedPermissions != web.plugin.grantedPermissions
        || info.grantedNetworkDomains != web.plugin.grantedNetworkDomains
      {
        launch()
      }
    case .script(let script):
      script.updatePlugin(status == .ready ? center.runtimeInfo(pluginID: pluginID) : nil)
    case .empty, .message, .approval, .builtin:
      break
    }
  }

  /// 开发目录里的文件变了：网页工具重新加载页面。
  func pluginFilesDidChange() {
    guard !isTornDown, case .web(let web) = content else { return }
    web.reloadFromDisk()
  }

  /// 插件被卸载：撤下内容并说明。
  func pluginWasRemoved() {
    guard !isTornDown else { return }
    startGeneration += 1
    showMessage(L("插件已卸载"), style: .info, status: nil)
  }

  // MARK: 判断与分派

  /// 按插件状态决定显示什么：找不到 / 已停用 → 提示；需要确认 → 授权提示；可运行 → 运行。
  /// 用户来源插件运行前先在后台核对文件摘要。
  private func start() {
    guard !isTornDown else { return }
    startGeneration += 1
    let generation = startGeneration
    let entry = request.entry
    let status = center.pluginStatus(pluginID: entry.pluginID)
    switch status {
    case nil:
      showMessage(L("找不到插件「\(entry.pluginName)」，它可能已被移除"), style: .error, status: nil)
    case .disabled?:
      showMessage(L("「\(entry.pluginName)」已停用，可以在设置的「工具」里重新启用"), style: .info, status: .disabled)
    case .needsApproval(let reason)?:
      showApproval(reason)
    case .ready?:
      guard entry.source == .user else {
        launch()
        return
      }
      replaceContent(.message(ToolSessionRunningView(text: L("正在检查插件文件…")), status: .ready))
      Task { [weak self] in
        guard let self else { return }
        let verified = await self.center.prepareToRun(pluginID: entry.pluginID)
        guard !self.isTornDown, generation == self.startGeneration else { return }
        if verified == .ready { self.launch() } else { self.start() }
      }
    }
  }

  /// 按功能动作创建内容。功能以工具中心里当前的清单为准，避免用过期的条目运行。
  private func launch() {
    let entry = request.entry
    if let view = request.view {
      launchPanel(view)
      return
    }
    guard let feature = center.manifest(pluginID: entry.pluginID)?.feature(code: entry.feature.code) else {
      showMessage(L("插件里已经没有「\(entry.feature.title)」这个功能了"), style: .error, status: .ready)
      return
    }
    if case .builtin(let action) = feature.action {
      showBuiltin(action.handler)
      return
    }
    guard let info = center.runtimeInfo(pluginID: entry.pluginID) else {
      start()
      return
    }
    switch feature.action {
    case .ui: showWeb(info)
    case .script(let action) where action.output == .terminal: runInTerminal(action, feature: feature, info: info)
    case .script(let action): showScript(action, feature: feature, info: info)
    case .builtin: break
    }
  }

  /// panel 视图：入口是视图声明的 `main`，不要求清单有 `ui`。合成的 `view:<id>` 功能不在清单里，
  /// 改为核对当前清单里仍有这个 panel 视图。
  private func launchPanel(_ view: ToolViewPlacement) {
    let pluginID = request.entry.pluginID
    guard let current = center.manifest(pluginID: pluginID)?.view(id: view.contribution.id), current.kind == .panel,
      current.main != nil
    else {
      showMessage(L("插件里已经没有「\(view.contribution.title)」这个视图了"), style: .error, status: .ready)
      return
    }
    guard let info = center.runtimeInfo(pluginID: pluginID) else {
      start()
      return
    }
    showWeb(info)
  }

  /// 授权提示；点按钮后弹安装确认，同意后重新判断（这时状态已是可运行）。
  private func showApproval(_ reason: ToolApprovalReason) {
    let pluginID = request.entry.pluginID
    guard let manifest = center.manifest(pluginID: pluginID) else { return }
    let generation = startGeneration
    let prompt = ToolApprovalPromptView(manifest: manifest, reason: reason) { [weak self] in
      self?.requestApproval(generation: generation)
    }
    replaceContent(.approval(prompt, status: .needsApproval(reason)))
  }

  /// 弹安装确认；用户同意后开始运行。
  private func requestApproval(generation: Int) {
    guard case .approval(let prompt, _) = content else { return }
    prompt.setBusy(true)
    let pluginID = request.entry.pluginID
    Task { [weak self] in
      guard let self else { return }
      let approved = await self.center.approve(pluginID: pluginID, window: self.hostWindow)
      guard !self.isTornDown, generation == self.startGeneration else { return }
      prompt.setBusy(false)
      if approved { self.start() }
    }
  }

  /// 原生内置工具。
  private func showBuiltin(_ handler: ToolBuiltinHandler) {
    let actions = BuiltinToolActions(
      copy: { [weak self] text in self?.copyToPasteboard(text) },
      insertIntoTerminal: { [weak self] text in self?.insertIntoTerminal(text) },
      showNotice: { [weak self] text, isError in self?.notice(text, isError: isError) },
      heightDidChange: { [weak self] in self?.requestHeightUpdate() },
      resultDidChange: {},
      window: { [weak self] in self?.hostWindow },
      terminalStyle: { [weak self] in self?.center.terminalStyle() ?? ToolTerminalStyle.current() })
    replaceContent(.builtin(BuiltinToolContentFactory.make(handler: handler, input: request.input, actions: actions)))
  }

  /// text / list / none 脚本。
  private func showScript(_ action: ToolScriptAction, feature: ToolFeature, info: ToolPluginRuntimeInfo) {
    let actions = ScriptToolActions(
      copy: { [weak self] text in self?.copyToPasteboard(text) },
      insertIntoTerminal: { [weak self] text in self?.insertIntoTerminal(text) },
      openInPane: { [weak self] in
        guard let self else { return }
        self.host?.toolSessionOpenInPane(self)
      },
      showNotice: { [weak self] text, isError in self?.notice(text, isError: isError) },
      requestClose: { [weak self] in
        guard let self, !self.isTornDown else { return }
        self.host?.toolSessionDidRequestClose(self)
      },
      contentDidChange: { [weak self] in self?.requestHeightUpdate() })
    let script = ScriptToolController(action: action, feature: feature, plugin: info, input: request.input, actions: actions)
    replaceContent(.script(script))
    script.start()
  }

  /// terminal 脚本：在后台解析命令后交给容器在新终端标签里运行，然后关闭工具。
  private func runInTerminal(_ action: ToolScriptAction, feature: ToolFeature, info: ToolPluginRuntimeInfo) {
    let generation = startGeneration
    let input = request.input
    replaceContent(.message(ToolSessionRunningView(text: L("正在打开终端…")), status: .ready))
    Task { [weak self] in
      let launch: Result<(command: [String], workingDirectory: String, environment: [String: String]), ScriptToolError>
      do {
        launch = .success(try await Self.terminalLaunch(action: action, code: feature.code, plugin: info, input: input))
      } catch let error as ScriptToolError {
        launch = .failure(error)
      } catch {
        launch = .failure(.launchFailed(error.localizedDescription))
      }
      guard let self, !self.isTornDown, generation == self.startGeneration else { return }
      switch launch {
      case .failure(let error):
        self.showMessage(error.localizedMessage, style: .error, status: .ready)
      case .success(let command):
        // 先换成完成状态再请求关闭：容器可能在关闭回调里同步 teardown。
        self.showMessage(L("已在新终端标签里运行"), style: .success, status: .ready)
        self.host?.toolSession(
          self, runInTerminal: command.command, workingDirectory: command.workingDirectory,
          environment: command.environment)
        self.notice(L("已在新终端标签里运行"), isError: false)
        self.host?.toolSessionDidRequestClose(self)
      }
    }
  }

  /// 后台解析 terminal 脚本的命令。
  @concurrent
  private nonisolated static func terminalLaunch(
    action: ToolScriptAction, code: String, plugin: ToolPluginRuntimeInfo, input: ToolInput
  ) async throws -> (command: [String], workingDirectory: String, environment: [String: String]) {
    try ScriptToolRunner.terminalLaunch(action: action, code: code, plugin: plugin, input: input, query: input.text)
  }

  /// 网页工具。
  private func showWeb(_ info: ToolPluginRuntimeInfo) {
    webHeight = nil
    let web = WebToolViewController(plugin: info, request: request, host: self)
    replaceContent(.web(web))
  }

  // MARK: 内容切换

  /// 提示。
  private func showMessage(_ text: String, style: ToolSessionMessageView.Style, status: ToolPluginStatus?) {
    replaceContent(.message(ToolSessionMessageView(text: text, style: style), status: status))
  }

  /// 撤下旧内容（取消脚本、释放 WebView）并装上新内容，然后通知容器高度。
  private func replaceContent(_ newContent: Content) {
    switch content {
    case .builtin(let tool): tool.teardown()
    case .script(let script): script.teardown()
    case .web(let web):
      web.teardown()
      web.removeFromParent()
    case .empty, .message, .approval: break
    }
    rootView.subviews.forEach { $0.removeFromSuperview() }
    content = newContent
    let newView: NSView? =
      switch newContent {
      case .empty: nil
      case .message(let view, _): view
      case .approval(let view, _): view
      case .builtin(let tool): tool.view
      case .script(let script): script.view
      case .web(let web): web.view
      }
    if case .web(let web) = newContent { addChild(web) }
    if let newView {
      rootView.addSubview(newView)
      newView.pinEdges(to: rootView)
    }
    if !isTornDown { requestHeightUpdate() }
  }

  /// 告诉容器当前希望的高度。panel 视图的高度由位置决定，只转交页面明确的 `ui.setHeight`（见 `webTool(_:didRequestHeight:)`）。
  private func requestHeightUpdate() {
    guard !isTornDown, request.view == nil else { return }
    host?.toolSession(self, didRequestHeight: preferredHeight)
  }

  // MARK: 动作

  /// 弹框挂靠的窗口。
  private var hostWindow: NSWindow? {
    host?.toolSessionWindow ?? (isViewLoaded ? view.window : nil)
  }

  /// 写剪贴板并提示。
  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    notice(L("已复制"), isError: false)
  }

  /// 预填到来源终端；失败原因由容器提示。
  private func insertIntoTerminal(_ text: String) {
    guard let host, host.toolSession(self, insertIntoTerminal: text) else { return }
    notice(L("已预填到终端"), isError: false)
  }

  /// 在容器里显示短提示。
  private func notice(_ text: String, isError: Bool) {
    guard !isTornDown else { return }
    host?.toolSession(self, showNotice: text, isError: isError)
  }

  // MARK: ToolWebHost

  /// 只认当前挂着的网页控制器；被替换掉的旧控制器迟到的回调直接丢弃。
  private func isCurrent(_ controller: WebToolViewController) -> Bool {
    guard !isTornDown, case .web(let web) = content else { return false }
    return web === controller
  }

  func webTool(_ controller: WebToolViewController, didRequestHeight height: CGFloat) {
    guard isCurrent(controller) else { return }
    // panel 视图：桥接已按位置夹过范围，原样交给容器（侧栏改高度，Inspector 忽略）。
    if request.view != nil {
      host?.toolSession(self, didRequestHeight: height)
      return
    }
    webHeight = min(max(height, CGFloat(ToolUIConfig.heightRange.lowerBound)), CGFloat(ToolUIConfig.heightRange.upperBound))
    requestHeightUpdate()
  }

  func webToolDidRequestClose(_ controller: WebToolViewController) {
    guard isCurrent(controller) else { return }
    host?.toolSessionDidRequestClose(self)
  }

  func webTool(_ controller: WebToolViewController, insertIntoTerminal text: String) -> String? {
    guard isCurrent(controller) else { return L("工具已关闭") }
    guard let origin = request.origin else { return L("没有可以预填的终端") }
    return origin.insert(text)
  }

  func webToolTerminalSelection(_ controller: WebToolViewController) -> String? {
    guard isCurrent(controller) else { return nil }
    return request.origin?.selectedText
  }

  func webTool(_ controller: WebToolViewController, showNotice text: String, isError: Bool) {
    guard isCurrent(controller) else { return }
    notice(text, isError: isError)
  }

  var webToolWindow: NSWindow? { hostWindow }
}
