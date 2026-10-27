// 网页工具的 `aster-plugin://` scheme handler：只把本插件目录里的普通文件交给 WebKit。
import Foundation
import WebKit

/// 为单个插件提供页面资源。路径判断与读文件在后台进行；WebKit 叫停的任务不再回调。
@MainActor
final class PluginSchemeHandler: NSObject, WKURLSchemeHandler {
  private let pluginID: String
  private let root: URL
  /// 已开始、尚未完成也没被叫停的任务。只有仍在集合里的任务才能收到回调：
  /// WebKit 规定 `stop` 之后再回调会抛 Objective-C 异常。
  private var activeTasks: Set<ObjectIdentifier> = []
  private var isInvalidated = false

  /// `root` 是插件根目录；`pluginID` 必须与地址里的 host 完全一致。
  init(pluginID: String, root: URL) {
    self.pluginID = pluginID
    self.root = root
    super.init()
  }

  /// 释放后不再回应任何任务；WebView 销毁时会对未完成的任务调用 `stop`。
  func invalidate() {
    isInvalidated = true
    activeTasks.removeAll()
  }

  /// 开始加载：登记任务，在后台解析路径并读文件，回到主线程后确认任务仍然有效再回应。
  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard !isInvalidated else {
      urlSchemeTask.didFailWithError(URLError(.cancelled))
      return
    }
    let key = ObjectIdentifier(urlSchemeTask)
    activeTasks.insert(key)
    let url = urlSchemeTask.request.url
    let pluginID = pluginID
    let root = root
    // 闭包持有任务对象直到回应结束，它的地址不会被别的任务复用，ObjectIdentifier 因此可靠。
    Task { [weak self] in
      let response = await Task.detached(priority: .userInitiated) {
        PluginResourceResolver.load(url: url, pluginID: pluginID, root: root)
      }.value
      guard let self, self.activeTasks.remove(key) != nil else { return }
      Self.respond(response, to: urlSchemeTask)
    }
  }

  /// WebKit 叫停任务（导航取消、页面关闭）：移出集合，后台结果回来后直接丢弃。
  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    activeTasks.remove(ObjectIdentifier(urlSchemeTask))
  }

  /// 把加载结果写回任务：响应头、正文、完成。
  private static func respond(_ response: PluginResourceResponse, to task: any WKURLSchemeTask) {
    guard let url = task.request.url,
      let httpResponse = HTTPURLResponse(
        url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headers)
    else {
      task.didFailWithError(URLError(.badURL))
      return
    }
    task.didReceive(httpResponse)
    if !response.body.isEmpty { task.didReceive(response.body) }
    task.didFinish()
  }
}
