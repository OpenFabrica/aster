// 网页工具 WKWebView 集成：真实加载临时目录里的最小插件，验证桥接注入、事件推送、CSP 与未声明权限被拒；
// 另含导航规则的纯函数用例。
import AppKit
import Foundation
import Testing
import WebKit

@testable import Aster
@testable import AsterCore

/// 记录回调的假宿主。
@MainActor
private final class FakeWebHost: ToolWebHost {
  private(set) var heights: [CGFloat] = []
  private(set) var closeCount = 0
  private(set) var notices: [String] = []

  func webTool(_ controller: WebToolViewController, didRequestHeight height: CGFloat) { heights.append(height) }
  func webToolDidRequestClose(_ controller: WebToolViewController) { closeCount += 1 }
  func webTool(_ controller: WebToolViewController, insertIntoTerminal text: String) -> String? { nil }
  func webToolTerminalSelection(_ controller: WebToolViewController) -> String? { nil }
  func webTool(_ controller: WebToolViewController, showNotice text: String, isError: Bool) { notices.append(text) }
  var webToolWindow: NSWindow? { nil }
}

/// 在页面里求值并转成字符串。
@MainActor
private func evaluate(_ script: String, in webView: WKWebView) async throws -> String {
  try await withCheckedThrowingContinuation { continuation in
    webView.evaluateJavaScript(script) { result, error in
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume(returning: result as? String ?? "")
      }
    }
  }
}

/// 反复求值直到满足条件或约 3 秒超时，返回最后一次的值。
@MainActor
private func waitForValue(
  _ script: String,
  in webView: WKWebView,
  until predicate: (String) -> Bool
) async throws -> String {
  var value = ""
  for _ in 0..<150 {
    value = try await evaluate(script, in: webView)
    if predicate(value) { return value }
    try await Task.sleep(for: .milliseconds(20))
  }
  return value
}

/// 用临时插件目录建好控制器并加载页面。
@MainActor
private func loadWebTool(files: [String: String], host: FakeWebHost, text: String? = nil) throws
  -> (WebToolViewController, WKWebView, URL)
{
  let directory = try makeTemporaryPluginDirectory(files: files)
  let controller = WebToolViewController(
    plugin: makeWebToolPlugin(directory: directory), request: makeWebToolRequest(text: text), host: host)
  controller.dataStoreOverride = .nonPersistent()
  controller.servicesOverride = FakeToolBridgeServices()
  controller.loadViewIfNeeded()
  let webView = try #require(controller.webViewForTesting)
  return (controller, webView, directory)
}

private let pageHTML = """
  <!doctype html><html><head><meta charset="utf-8">
  <script src="main.js"></script><script type="module" src="module.mjs"></script></head>
  <body><script>document.documentElement.dataset.inline = "ran";</script></body></html>
  """

@Test("真实 WebView：注入桥接、发送 enter、CSP 拦截内联脚本、WebRTC 被移除、未声明权限的调用被拒")
@MainActor
func webToolLoadsPluginAndRejectsUndeclaredPermission() async throws {
  let host = FakeWebHost()
  let (controller, webView, directory) = try loadWebTool(
    files: [
      "index.html": pageHTML,
      "main.js": """
        aster.onEnter((event) => {
          const frame = document.createElement("iframe");
          document.body.appendChild(frame);
          document.documentElement.dataset.webrtc =
            typeof window.RTCPeerConnection + "/" + typeof frame.contentWindow.RTCPeerConnection;
          document.documentElement.dataset.enterCode = event.code;
          document.documentElement.dataset.enterText = event.input.text;
        });
        aster.clipboard.writeText("x").then(
          () => { document.title = "resolved"; },
          (error) => { document.title = "rejected:" + error.code + ":" + (error instanceof aster.AsterError); });
        """,
      "module.mjs": "document.documentElement.dataset.module = 'ok';",
    ], host: host, text: "hello")
  defer {
    controller.teardown()
    try? FileManager.default.removeItem(at: directory)
  }

  let title = try await waitForValue("document.title", in: webView) { $0.hasPrefix("rejected") || $0 == "resolved" }
  #expect(title == "rejected:permission_denied:true")
  let enterText = try await waitForValue("document.documentElement.dataset.enterText || ''", in: webView) {
    !$0.isEmpty
  }
  #expect(enterText == "hello")
  #expect(try await evaluate("document.documentElement.dataset.enterCode || ''", in: webView) == "main")
  #expect(try await evaluate("document.documentElement.dataset.module || ''", in: webView) == "ok")
  #expect(try await evaluate("document.documentElement.dataset.inline || 'blocked'", in: webView) == "blocked")
  // 脚本创建的 about:blank iframe 不受 CSP frame-src 约束，WebRTC 也必须在里面被移除。
  #expect(try await evaluate("document.documentElement.dataset.webrtc || ''", in: webView) == "undefined/undefined")
  #expect(try await evaluate("document.documentElement.dataset.asterAppearance || ''", in: webView) == "light")
  #expect(host.notices.isEmpty)
}

@Test("deliver、updateQuery、applyAppearance 送达 enter、query、theme；ui.setHeight 转给宿主；teardown 后释放 WebView")
@MainActor
func webToolDeliversEventsAndHeight() async throws {
  let host = FakeWebHost()
  let (controller, webView, directory) = try loadWebTool(
    files: [
      "index.html": "<!doctype html><html><head><script src=\"main.js\"></script></head><body></body></html>",
      "main.js": """
        const root = document.documentElement;
        aster.onEnter((event) => {
          root.dataset.enterText = event.input.text || "";
          root.dataset.enterCount = String(Number(root.dataset.enterCount || 0) + 1);
        });
        aster.onQuery((text) => { root.dataset.query = text; });
        aster.onThemeChange((theme) => { root.dataset.theme = theme.appearance; });
        aster.setHeight(250);
        """,
    ], host: host)
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(try await waitForValue("document.documentElement.dataset.enterCount || ''", in: webView) { $0 == "1" } == "1")
  #expect(host.heights == [250])
  #expect(controller.preferredHeight == 250)

  controller.updateQuery("abc")
  #expect(try await waitForValue("document.documentElement.dataset.query || ''", in: webView) { $0 == "abc" } == "abc")
  controller.applyAppearance("dark")
  #expect(try await waitForValue("document.documentElement.dataset.theme || ''", in: webView) { $0 == "dark" } == "dark")
  #expect(try await evaluate("document.documentElement.dataset.asterAppearance", in: webView) == "dark")
  controller.deliver(input: ToolInput(text: "next", source: .clipboard))
  #expect(
    try await waitForValue("document.documentElement.dataset.enterText || ''", in: webView) { $0 == "next" } == "next")

  controller.teardown()
  #expect(controller.webViewForTesting == nil)
  controller.updateQuery("ignored")
  #expect(host.closeCount == 0)
}

@Test("导航规则：本插件地址放行；用户刚点过的 http(s) 链接交给浏览器；脚本跳转与其它地址拦截")
func webToolNavigationPolicyDecisions() throws {
  /// 以测试插件身份判断一次导航。
  func decide(_ text: String, link: Bool = true, user: Bool = true) -> WebToolNavigationDecision {
    WebToolNavigationPolicy.decide(
      url: URL(string: text), pluginID: "com.example.webtest", isLinkActivation: link, hasRecentUserInput: user)
  }
  #expect(decide("aster-plugin://com.example.webtest/page.html", link: false, user: false) == .allow)
  let external = try #require(URL(string: "https://example.com/docs"))
  #expect(decide("https://example.com/docs") == .openExternally(external))
  #expect(decide("https://example.com/docs", user: false) == .cancel)
  #expect(decide("https://example.com/docs", link: false) == .cancel)
  #expect(decide("aster-plugin://com.example.other/index.html") == .cancel)
  #expect(decide("javascript:alert(1)") == .cancel)
  #expect(decide("file:///etc/passwd") == .cancel)
  #expect(decide("data:text/html,hi") == .cancel)
  #expect(
    WebToolNavigationPolicy.entryURL(pluginID: "com.example.webtest", mainPath: "ui/my page.html")?.absoluteString
      == "aster-plugin://com.example.webtest/ui/my%20page.html")
}
