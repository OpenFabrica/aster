// `window.webkit.messageHandlers.aster` 的 WebKit 接收端：只把本插件主 frame 的消息交给桥接。
import AsterCore
import WebKit

/// `WKUserContentController` 强持有消息处理者，所以这里只弱引用桥接，避免
/// `WKWebView → 配置 → 代理 → 桥接 → 控制器 → WKWebView` 的保留环。
@MainActor
final class ToolBridgeMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
  weak var bridge: ToolBridge?
  private let pluginID: String

  /// `pluginID` 用来核对消息来自本插件的页面。
  init(bridge: ToolBridge, pluginID: String) {
    self.bridge = bridge
    self.pluginID = pluginID
    super.init()
  }

  /// 收到页面消息：子 frame 或非本插件地址的页面一律拒绝，其余交给桥接，桥接负责回复。
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    // CSP 已经禁止子 frame，导航策略也只放行本插件地址；这里按 frame 与地址再兜一次底，
    // 万一有页面绕过前两层，也拿不到任何桥接能力。
    guard message.frameInfo.isMainFrame,
      WebToolNavigationPolicy.isPluginURL(message.frameInfo.request.url, pluginID: pluginID)
    else {
      replyHandler(nil, ToolBridgeError.unavailable(L("只接受插件主页面的调用")).replyString)
      return
    }
    guard let bridge else {
      replyHandler(nil, ToolBridgeError.unavailable(L("工具已关闭")).replyString)
      return
    }
    bridge.handle(body: message.body, reply: replyHandler)
  }
}
