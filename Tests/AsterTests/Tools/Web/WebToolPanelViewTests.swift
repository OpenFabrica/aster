// 网页工具作为插件 panel 视图运行：入口取视图声明的 `main`、enter 带视图身份与扩展上下文、
// 换上下文只推 `context` 事件不重新进入；桥接 `context.get` 返回同一份上下文。
import AppKit
import Foundation
import Testing
import WebKit

@testable import Aster
@testable import AsterCore

/// 什么都不做的网页宿主，只记录提示。
@MainActor
private final class PanelWebHost: ToolWebHost {
  private(set) var notices: [String] = []

  func webTool(_ controller: WebToolViewController, didRequestHeight height: CGFloat) {}
  func webToolDidRequestClose(_ controller: WebToolViewController) {}
  func webTool(_ controller: WebToolViewController, insertIntoTerminal text: String) -> String? { nil }
  func webToolTerminalSelection(_ controller: WebToolViewController) -> String? { nil }
  func webTool(_ controller: WebToolViewController, showNotice text: String, isError: Bool) { notices.append(text) }
  var webToolWindow: NSWindow? { nil }
}

/// 反复读 `<html>` 上的 data 属性直到满足条件或约 3 秒超时，返回最后一次的值。
@MainActor
private func pageData(
  _ key: String,
  in webView: WKWebView,
  until predicate: (String) -> Bool = { !$0.isEmpty }
) async throws -> String {
  var value = ""
  for _ in 0..<150 {
    value = try await withCheckedThrowingContinuation { continuation in
      webView.evaluateJavaScript("document.documentElement.dataset.\(key) || ''") { result, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: result as? String ?? "")
        }
      }
    }
    if predicate(value) { return value }
    try await Task.sleep(for: .milliseconds(20))
  }
  return value
}

/// `inspector.panel` 上的 `status` 视图，入口 `views/panel.html`。
private let panelPlacement = ToolViewPlacement(
  contribution: ToolViewContribution(
    id: "status", title: "Status", kind: .panel, slot: .inspectorPanel, main: "views/panel.html"),
  slot: .inspectorPanel)

/// 打开 panel 视图的请求：带视图身份与扩展上下文。
private func makePanelRequest(extended: [String: JSONValue]) -> ToolLaunchRequest {
  var request = makeWebToolRequest()
  request.view = panelPlacement
  request.extendedContext = extended
  return request
}

private let panelScript = """
  const root = document.documentElement;
  const bump = (key) => { root.dataset[key] = String(Number(root.dataset[key] || 0) + 1); };
  aster.onEnter((event) => {
    bump("enterCount");
    root.dataset.view = event.view ? event.view.id + "@" + event.view.slot : "none";
    root.dataset.enterBranch = event.context.branch || "";
  });
  aster.onContextChange((context) => {
    bump("contextCount");
    root.dataset.contextBranch = context.branch || "";
    root.dataset.contextCwd = context.workingDirectory || "";
  });
  """

@Test("panel 视图的入口取视图声明的 main，不用清单 ui.main；enter 带视图身份与扩展上下文")
@MainActor
func panelEntryPathOverridesManifestMain() async throws {
  let directory = try makeTemporaryPluginDirectory(files: [
    "index.html": "<!doctype html><html data-page=\"tool\"><body></body></html>",
    "views/panel.html":
      "<!doctype html><html data-page=\"panel\"><head><script src=\"panel.js\"></script></head><body></body></html>",
    "views/panel.js": panelScript,
  ])
  defer { try? FileManager.default.removeItem(at: directory) }
  let host = PanelWebHost()
  let controller = WebToolViewController(
    plugin: makeWebToolPlugin(directory: directory), request: makePanelRequest(extended: ["branch": "main"]),
    host: host)
  controller.dataStoreOverride = .nonPersistent()
  controller.servicesOverride = FakeToolBridgeServices()
  #expect(controller.entryPath == "views/panel.html")
  controller.loadViewIfNeeded()
  defer { controller.teardown() }
  let webView = try #require(controller.webViewForTesting)

  #expect(try await pageData("page", in: webView) == "panel")
  #expect(try await pageData("view", in: webView) == "status@inspector.panel")
  #expect(try await pageData("enterBranch", in: webView) == "main")
  #expect(host.notices.isEmpty)

  // 普通网页工具仍走清单的 ui.main。
  let plain = WebToolViewController(
    plugin: makeWebToolPlugin(directory: directory), request: makeWebToolRequest(), host: host)
  #expect(plain.entryPath == "index.html")
}

@Test("updateContext 只推 context 事件：页面收到新分支与目录，enter 不重发")
@MainActor
func contextEventReachesPage() async throws {
  let directory = try makeTemporaryPluginDirectory(files: [
    "views/panel.html": "<!doctype html><html><head><script src=\"panel.js\"></script></head><body></body></html>",
    "views/panel.js": panelScript,
  ])
  defer { try? FileManager.default.removeItem(at: directory) }
  let host = PanelWebHost()
  let controller = WebToolViewController(
    plugin: makeWebToolPlugin(directory: directory), request: makePanelRequest(extended: ["branch": "main"]),
    host: host)
  controller.dataStoreOverride = .nonPersistent()
  controller.servicesOverride = FakeToolBridgeServices()
  controller.loadViewIfNeeded()
  defer { controller.teardown() }
  let webView = try #require(controller.webViewForTesting)
  #expect(try await pageData("enterCount", in: webView) == "1")
  // enter 本身也通知一次上下文监听者。
  #expect(try await pageData("contextBranch", in: webView) == "main")

  let input = ToolInput(context: ToolContext(workingDirectory: "/tmp/project", locale: "zh-Hans", appearance: "light"))
  controller.updateContext(input, extended: ["branch": "dev"])
  #expect(try await pageData("contextBranch", in: webView) { $0 == "dev" } == "dev")
  #expect(try await pageData("contextCwd", in: webView) == "/tmp/project")
  #expect(try await pageData("contextCount", in: webView) == "2")
  #expect(try await pageData("enterCount", in: webView) == "1")
  #expect(controller.request.extendedContext == ["branch": "dev"])
  #expect(controller.request.input.context.workingDirectory == "/tmp/project")
}

@Test("context.get 返回 ToolContext 并入扩展上下文，基础字段不被扩展上下文改写；enter 结构与之一致")
@MainActor
func contextGetReturnsExtendedContext() async throws {
  let directory = try makeTemporaryPluginDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let request = makePanelRequest(extended: [
    "branch": "main", "paneID": "p-1", "agent": ["provider": "claude", "state": "running"],
    "locale": "xx",
  ])
  let bridge = ToolBridge(plugin: makeWebToolPlugin(directory: directory), services: FakeToolBridgeServices())
  let delegate = FakeToolBridgeDelegate(request: request)
  bridge.delegate = delegate
  defer { withExtendedLifetime(delegate) {} }

  let reply = await callBridge(bridge, "context.get")
  #expect(reply.error == nil)
  let json = try #require(reply.json)
  let context = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
  #expect(
    context == [
      "isRemote": false, "locale": "zh-Hans", "appearance": "light", "branch": "main", "paneID": "p-1",
      "agent": ["provider": "claude", "state": "running"],
    ])

  // tool.input 与 enter 共用的载荷：同一份上下文，外加视图身份。
  let payload = try ToolBridge.toolInputPayload(for: request)
  guard case .object(let fields) = payload else { throw TestFailure() }
  #expect(fields["context"] == context)
  #expect(fields["view"] == ["id": "status", "slot": "inspector.panel"])
  #expect(fields["code"] == "main")
}

/// `guard case` 失败时抛出。
private struct TestFailure: Error {}
