// 网页工具的导航规则：只放行本插件 `aster-plugin://<id>/` 下的地址；用户刚点过的 http(s) 链接交给系统浏览器，
// 其它跳转一律拦截。纯函数，WebKit 委托方法只负责把结论落地。
import AsterCore
import Foundation

/// 一次导航的处理结论。
enum WebToolNavigationDecision: Equatable {
  /// 在 WebView 里继续加载（本插件的页面）。
  case allow
  /// 取消导航，改由系统默认浏览器打开。
  case openExternally(URL)
  /// 直接取消。
  case cancel
}

/// 网页工具导航规则。
enum WebToolNavigationPolicy {
  /// 用户点击后这段时间内触发的链接导航才算「用户点击」（秒）。
  static let userInputGracePeriod: TimeInterval = 1

  /// 插件入口页地址：`aster-plugin://<pluginID>/<mainPath>`，路径里的特殊字符按 URL 规则编码。
  static func entryURL(pluginID: String, mainPath: String) -> URL? {
    var components = URLComponents()
    components.scheme = ToolBridgeProtocol.scheme
    components.host = pluginID
    components.path = "/" + mainPath
    return components.url
  }

  /// 地址是否属于本插件（scheme 与 host 完全一致，没有端口和用户信息）。路径由 scheme handler 再校验。
  static func isPluginURL(_ url: URL?, pluginID: String) -> Bool {
    guard let url else { return false }
    return url.scheme?.lowercased() == ToolBridgeProtocol.scheme
      && url.host(percentEncoded: false) == pluginID
      && url.port == nil && url.user == nil && url.password == nil
  }

  /// 根据地址、是否链接点击、是否刚有用户输入，决定放行、交给系统浏览器还是拦截。
  static func decide(
    url: URL?,
    pluginID: String,
    isLinkActivation: Bool,
    hasRecentUserInput: Bool
  ) -> WebToolNavigationDecision {
    if isPluginURL(url, pluginID: pluginID) { return .allow }
    // 只有「用户刚在页面里点击或按键」且导航类型是链接点击时才交给浏览器：
    // 脚本里的 `a.click()` 同样报告为链接点击，单看导航类型无法挡住静默外发数据。
    guard isLinkActivation, hasRecentUserInput, let url, WebPaneURLPolicy.allows(url) else { return .cancel }
    return .openExternally(url)
  }
}
