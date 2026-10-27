// 网页工具的 WKWebView 宿主：沙箱配置、`aster-plugin://` 加载、导航拦截、`window.aster` 桥接与事件推送。
// 协议与安全边界见 docs/developer/tools-and-plugins.md「网页工具」「权限与信任」。
import AppKit
import AsterCore
import WebKit

/// 在沙箱 WKWebView 里运行一个网页工具，并处理 `window.aster` 桥接请求。
@MainActor
final class WebToolViewController: NSViewController {
  /// 网页运行时脚本在资源目录里的位置。
  static let bridgeScriptPath = "tool-runtime/aster-bridge.js"
  /// 页面进程连续崩溃时最多自动重载的次数，超过后停在错误提示，避免崩溃—重载死循环。
  private static let maximumCrashReloads = 2
  /// 同一网址在这段时间内只交给系统浏览器一次（秒）。导航策略与新窗口回调可能先后报告同一次点击。
  private static let externalOpenDedupInterval: TimeInterval = 1
  /// 运行时脚本只读一次；读不到时不缓存，下次打开工具再试。
  private static var cachedBridgeScript: String?

  let plugin: ToolPluginRuntimeInfo
  private(set) var request: ToolLaunchRequest
  weak var host: ToolWebHost?

  /// 页面希望的内容高度（点）；初值取清单的 `ui.height`，之后跟随 `ui.setHeight`。
  private(set) var preferredHeight: CGFloat
  /// 注入点：替换网站数据存储（默认是按插件 id 推导的持久存储）。必须在视图加载前设置，测试用。
  var dataStoreOverride: WKWebsiteDataStore?
  /// 注入点：替换剪贴板、对话框、通知等系统能力。必须在视图加载前设置，测试用。
  var servicesOverride: (any ToolBridgeServices)?

  private var webView: ToolWebView?
  private var bridge: ToolBridge?
  private var messageProxy: ToolBridgeMessageProxy?
  private var schemeHandler: PluginSchemeHandler?
  private var entryURL: URL?
  /// 当前主 frame 文档已加载完成，可以接收事件。提交新文档时复位。
  private var isPageReady = false
  private var isTornDown = false
  /// 当前外观：`light` 或 `dark`。
  private var appearanceName: String
  private var crashReloadCount = 0
  private var lastExternalOpen: (url: URL, time: TimeInterval)?
  /// 缺资源、加载失败时显示的说明。
  private let errorLabel = NSTextField(wrappingLabelWithString: "")

  init(plugin: ToolPluginRuntimeInfo, request: ToolLaunchRequest, host: ToolWebHost) {
    self.plugin = plugin
    self.request = request
    self.host = host
    preferredHeight = CGFloat(plugin.manifest.resolvedUIHeight)
    appearanceName = Self.normalizedAppearance(request.input.context.appearance)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 测试读取页面内容用。
  var webViewForTesting: WKWebView? { webView }

  /// 搭建根视图：运行时脚本或入口缺失时只显示错误说明，不创建 WebView，也不回退到网络。
  override func loadView() {
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("web-tool-\(plugin.manifest.id)")
    configureErrorLabel(in: root)
    view = root
    guard !isTornDown else { return }
    guard let mainPath = plugin.manifest.ui?.main,
      let entryURL = WebToolNavigationPolicy.entryURL(pluginID: plugin.manifest.id, mainPath: mainPath)
    else {
      showError(L("这个插件没有网页界面"))
      return
    }
    guard let bridgeSource = Self.loadBridgeScript() else {
      showError(L("找不到网页工具运行时（aster-bridge.js），请重新构建 Aster。"))
      return
    }
    let webView = makeWebView(bridgeSource: bridgeSource)
    root.addSubview(webView, positioned: .below, relativeTo: errorLabel)
    webView.pinEdges(to: root)
    self.webView = webView
    self.entryURL = entryURL
    webView.load(URLRequest(url: entryURL))
  }

  // MARK: - 对外接口

  /// 换一份新输入重新进入：再次发送 `enter` 事件。
  func deliver(input: ToolInput) {
    request.input = input
    sendEnter()
  }

  /// 启动器搜索框文字变化：发送 `query` 事件。
  func updateQuery(_ text: String) {
    request.input.text = text
    send(.object(["type": "query", "text": .string(text)]))
  }

  /// 外观变化：WebView 外观同步切换（`prefers-color-scheme` 跟着变），并发送 `theme` 事件。
  func applyAppearance(_ appearance: String) {
    appearanceName = Self.normalizedAppearance(appearance)
    request.input.context.appearance = appearanceName
    webView?.appearance = Self.appearance(named: appearanceName)
    send(.object(["type": "theme", "theme": themeValue]))
  }

  /// 开发目录文件变化后重新加载页面；加载完成后重新发送 `enter`。
  func reloadFromDisk() {
    guard !isTornDown, let webView else { return }
    isPageReady = false
    crashReloadCount = 0
    hideError()
    if webView.url != nil {
      webView.reloadFromOrigin()
    } else if let entryURL {
      webView.load(URLRequest(url: entryURL))
    }
  }

  /// 释放 WebView 与桥接；之后不再回调 host，迟到的异步结果全部丢弃。
  func teardown() {
    guard !isTornDown else { return }
    isTornDown = true
    isPageReady = false
    bridge?.invalidate()
    bridge = nil
    schemeHandler?.invalidate()
    if let webView {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
      let contentController = webView.configuration.userContentController
      contentController.removeScriptMessageHandler(
        forName: ToolBridgeProtocol.messageHandlerName, contentWorld: .page)
      contentController.removeAllUserScripts()
      webView.removeFromSuperview()
    }
    webView = nil
    messageProxy = nil
    host = nil
  }

  // MARK: - WebView 配置

  /// 沙箱配置：每个插件独立的网站数据存储、只认 `aster-plugin` 的资源、只在 `.page` 世界注入桥接、
  /// 禁止脚本开新窗口；只有开发来源可以用 Web Inspector 调试。
  private func makeWebView(bridgeSource: String) -> ToolWebView {
    let pluginID = plugin.manifest.id
    let bridge = ToolBridge(plugin: plugin, services: servicesOverride ?? SystemToolBridgeServices())
    bridge.delegate = self
    let proxy = ToolBridgeMessageProxy(bridge: bridge, pluginID: pluginID)
    let schemeHandler = PluginSchemeHandler(pluginID: pluginID, root: plugin.directory)

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore =
      dataStoreOverride
      ?? WKWebsiteDataStore(forIdentifier: ToolPluginIdentity.dataStoreIdentifier(pluginID: pluginID))
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ToolBridgeProtocol.scheme)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    WebToolSandbox.disablePeerConnections(in: configuration.preferences)
    let contentController = configuration.userContentController
    contentController.addScriptMessageHandler(
      proxy, contentWorld: .page, name: ToolBridgeProtocol.messageHandlerName)
    contentController.addUserScript(WebToolSandbox.makeHardeningUserScript())
    contentController.addUserScript(
      WKUserScript(source: bridgeSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))

    let webView = ToolWebView(frame: .zero, configuration: configuration)
    webView.identifier = NSUserInterfaceItemIdentifier("web-tool-view")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    // 关掉 Force Touch 链接预览：预览会在另一个 WebView 里加载外部地址，绕过这里的导航拦截。
    webView.allowsLinkPreview = false
    webView.isInspectable = plugin.source == .development
    webView.setValue(false, forKey: "drawsBackground")
    webView.appearance = Self.appearance(named: appearanceName)
    self.bridge = bridge
    messageProxy = proxy
    self.schemeHandler = schemeHandler
    return webView
  }

  /// 从资源目录读 `tool-runtime/aster-bridge.js`；读不到返回 nil。
  private static func loadBridgeScript() -> String? {
    if let cachedBridgeScript { return cachedBridgeScript }
    guard let resources = AsterResourceLocations.resourcesDirectory() else { return nil }
    let url = resources.appendingPathComponent(bridgeScriptPath, isDirectory: false)
    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      cachedBridgeScript = source
      return source
    } catch {
      return nil
    }
  }

  // MARK: - 事件

  /// `theme` 事件与 `enter.theme` 的内容。
  private var themeValue: JSONValue { .object(["appearance": .string(appearanceName)]) }

  /// 发送 `enter`：`{type, code, input, context, theme}`。
  private func sendEnter() {
    let payload: JSONValue
    do {
      payload = try ToolBridge.toolInputPayload(for: request)
    } catch {
      host?.webTool(self, showNotice: L("无法把输入交给网页工具"), isError: true)
      return
    }
    guard case .object(var event) = payload else { return }
    event["type"] = .string("enter")
    event["theme"] = themeValue
    send(.object(event))
  }

  /// 把事件交给页面里的 `window.__asterReceive`。数据只经 `arguments` 结构化传入，绝不拼进脚本源码。
  /// 页面没加载完时不发：加载完成后的 `enter` 会带上最新的输入与外观。
  private func send(_ event: JSONValue) {
    guard isPageReady, !isTornDown, let webView else { return }
    webView.callAsyncJavaScript(
      "window.__asterReceive(event);",
      arguments: ["event": event.foundationObject],
      in: nil,
      in: .page,
      completionHandler: nil)
  }

  // MARK: - 辅助

  /// 用户刚点过的 http(s) 链接交给系统浏览器；同一网址短时间内只打开一次。
  private func openExternally(_ url: URL) {
    let now = ProcessInfo.processInfo.systemUptime
    if let last = lastExternalOpen, last.url == url, now - last.time < Self.externalOpenDedupInterval { return }
    lastExternalOpen = (url, now)
    NSWorkspace.shared.open(url)
  }

  /// 当前导航由用户点击触发时的决定。
  private func navigationDecision(for action: WKNavigationAction) -> WebToolNavigationDecision {
    WebToolNavigationPolicy.decide(
      url: action.request.url,
      pluginID: plugin.manifest.id,
      isLinkActivation: action.navigationType == .linkActivated,
      hasRecentUserInput: webView?.hasRecentUserInput() ?? false)
  }

  /// 居中的错误说明，平时隐藏。
  private func configureErrorLabel(in root: NSView) {
    errorLabel.font = .interface(ofSize: 12)
    errorLabel.textColor = .secondaryLabelColor
    errorLabel.alignment = .center
    errorLabel.isHidden = true
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(errorLabel)
    NSLayoutConstraint.activate([
      errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      errorLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -32),
    ])
  }

  /// 显示错误并隐藏页面。
  private func showError(_ text: String) {
    errorLabel.stringValue = text
    errorLabel.isHidden = false
    webView?.isHidden = true
  }

  /// 恢复显示页面。
  private func hideError() {
    errorLabel.isHidden = true
    webView?.isHidden = false
  }

  /// 只认 `dark`，其余一律当 `light`。
  private static func normalizedAppearance(_ value: String) -> String {
    value == "dark" ? "dark" : "light"
  }

  /// 外观名对应的系统外观。
  private static func appearance(named name: String) -> NSAppearance? {
    NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
  }
}

// MARK: - 导航

extension WebToolViewController: WKNavigationDelegate {
  /// 只放行本插件的地址；用户刚点过的 http(s) 链接交给系统浏览器；其它跳转与下载一律取消。
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    guard !isTornDown, !navigationAction.shouldPerformDownload else {
      decisionHandler(.cancel)
      return
    }
    switch navigationDecision(for: navigationAction) {
    case .allow:
      decisionHandler(.allow)
    case .openExternally(let url):
      decisionHandler(.cancel)
      openExternally(url)
    case .cancel:
      decisionHandler(.cancel)
    }
  }

  /// 主页面不是 200 或者是 WebView 显示不了的类型时取消，并显示原因。
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
      response.statusCode != 200
    {
      decisionHandler(.cancel)
      showError(L("找不到插件页面：\(response.url?.path ?? "")"))
      return
    }
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
  }

  /// 新文档已提交：在它加载完成前不发送事件。
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    isPageReady = false
  }

  /// 主 frame 加载完成：发送 `enter`。每次加载（含重载、站内跳转）都会重新发送。
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isTornDown else { return }
    isPageReady = true
    hideError()
    sendEnter()
  }

  /// 加载失败（导航被策略取消的不算）。
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    reportLoadFailure(error)
  }

  /// 提交后加载失败。
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    reportLoadFailure(error)
  }

  /// 页面进程退出（崩溃或被系统回收）：有限次数内自动重载并提示。
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isPageReady = false
    guard !isTornDown else { return }
    guard crashReloadCount < Self.maximumCrashReloads else {
      showError(L("网页工具意外退出"))
      return
    }
    crashReloadCount += 1
    host?.webTool(self, showNotice: L("网页工具意外退出，已重新加载"), isError: true)
    webView.reload()
  }

  /// 显示加载失败原因；导航被取消（含被本控制器的策略取消）不算失败。
  private func reportLoadFailure(_ error: Error) {
    guard !isTornDown else { return }
    let nsError = error as NSError
    let isCancellation =
      (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
      || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
    guard !isCancellation else { return }
    showError(L("网页工具加载失败：\(error.localizedDescription)"))
  }
}

// MARK: - 新窗口与权限

extension WebToolViewController: WKUIDelegate {
  /// 不开新窗口：本插件的地址就地打开，用户刚点过的 http(s) 链接交给系统浏览器，其余忽略。
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard !isTornDown else { return nil }
    switch navigationDecision(for: navigationAction) {
    case .allow: webView.load(navigationAction.request)
    case .openExternally(let url): openExternally(url)
    case .cancel: break
    }
    return nil
  }

  /// 摄像头、麦克风一律拒绝：插件没有对应权限。
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }
}

// MARK: - 桥接代理

extension WebToolViewController: ToolBridgeDelegate {
  var bridgeLaunchRequest: ToolLaunchRequest { request }

  var bridgePresentationWindow: NSWindow? { host?.webToolWindow ?? viewIfLoaded?.window }

  /// 记下页面希望的高度并转给宿主。
  func bridge(_ bridge: ToolBridge, didRequestHeight height: CGFloat) {
    guard !isTornDown else { return }
    preferredHeight = height
    host?.webTool(self, didRequestHeight: height)
  }

  /// 页面请求关闭工具。
  func bridgeDidRequestClose(_ bridge: ToolBridge) {
    guard !isTornDown else { return }
    host?.webToolDidRequestClose(self)
  }

  /// 预填到来源终端；工具已关闭或没有宿主时返回原因。
  func bridge(_ bridge: ToolBridge, insertIntoTerminal text: String) -> String? {
    guard !isTornDown, let host else { return L("工具已关闭") }
    return host.webTool(self, insertIntoTerminal: text)
  }

  /// 来源终端的选区。
  func bridgeTerminalSelection(_ bridge: ToolBridge) -> String? {
    guard !isTornDown else { return nil }
    return host?.webToolTerminalSelection(self)
  }
}
