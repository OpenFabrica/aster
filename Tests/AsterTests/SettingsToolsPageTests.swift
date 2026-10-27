// 设置页「工具」网页：tools. 动作名与 Swift 白名单一一对应，WKWebView 端到端渲染插件卡片、问题、开发目录与冲突快捷键。
import AppKit
import Foundation
import Testing
import WebKit

@testable import Aster
@testable import AsterCore

// MARK: - 网页

@Test("网页里出现的 tools. 动作与 Swift 白名单一一对应")
func settingsToolsWebActionsMatchBridge() throws {
  let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/settings-ui", isDirectory: true)
  let tools = try String(contentsOf: directory.appendingPathComponent("tools.js"), encoding: .utf8)
  let settings = try String(contentsOf: directory.appendingPathComponent("settings.js"), encoding: .utf8)
  let html = try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8)
  func matches(_ pattern: String, in text: String) throws -> Set<String> {
    let regex = try NSRegularExpression(pattern: pattern)
    return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range(at: 1), in: text).map { String(text[$0]) }
    })
  }
  let used = try matches(#"send\("(tools\.[A-Za-z]+)""#, in: tools)
    .union(matches(#"action\("(tools\.[A-Za-z]+)""#, in: settings))
  #expect(used == SettingsToolsBridge.actions)
  // tools.js 要在 settings.js 之前加载：settings.js 初始化时就读它的搜索条目。
  let toolsScript = try #require(html.range(of: "<script src=\"tools.js\" defer></script>"))
  let settingsScript = try #require(html.range(of: "<script src=\"settings.js\" defer></script>"))
  #expect(toolsScript.lowerBound < settingsScript.lowerBound)
}

/// 在设置页里执行一段脚本，取字符串结果。
@MainActor
private func evaluate(_ script: String, in webView: WKWebView) async throws -> String {
  try await withCheckedThrowingContinuation { continuation in
    webView.evaluateJavaScript(script) { result, error in
      if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: result as? String ?? "") }
    }
  }
}

/// 轮询直到脚本结果等于期望值（最多约 3 秒），返回最后一次的结果。
@MainActor
private func poll(_ script: String, until expected: String, in webView: WKWebView) async throws -> String {
  var value = ""
  for _ in 0..<150 {
    value = try await evaluate(script, in: webView)
    if value == expected { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  return value
}

@Test("设置页「工具」分类渲染插件卡片、问题、开发目录与冲突快捷键")
@MainActor
func settingsToolsPageRendersSnapshot() async throws {
  let preferences = isolatedToolsPreferences()
  preferences.setCompatibilityValue(.string("controlOptionSpace"), forKey: "quickTerminal.shortcut")
  let tools = FakeToolCenter()
  tools.pluginSummaries = [
    toolSummary(
      "com.example.jwt", name: "JWT 解析", status: .needsApproval(.permissionsAdded([.exec])),
      permissions: [.clipboardWrite, .exec, .network], granted: [.clipboardWrite], domains: ["api.example.com"]),
    toolSummary("com.example.dev", name: "开发插件", source: .development, directory: "/src/dev", description: nil),
    toolSummary("aster.builtin", name: "Aster 内置工具", source: .builtin, directory: ""),
  ]
  tools.pluginIssues = [ToolPluginIssue(path: "/plugins/broken", message: "清单无效：缺少 id")]
  tools.developmentFolders = ["/src/dev"]
  let bridge = SettingsToolsBridge(preferences: preferences, tools: tools)
  let controller = SettingsViewController(preferences: preferences, updateController: nil, toolsBridge: bridge)
  controller.loadViewIfNeeded()
  let webView = try #require(controller.settingsWebViewForTesting)

  #expect(try await poll("String(document.querySelectorAll('.nav-item').length)", until: "12", in: webView) == "12")
  _ = try await evaluate("document.querySelector('[data-section=\"tools\"]')?.click(); 'ok'", in: webView)
  #expect(try await poll("document.querySelector('.page-title')?.textContent ?? ''", until: "工具", in: webView) == "工具")

  func count(_ selector: String) async throws -> Int {
    Int(try await evaluate("String(document.querySelectorAll('\(selector)').length)", in: webView)) ?? -1
  }
  #expect(try await count(".tool-plugin") == 3)
  #expect(try await count(".tool-approval") == 1)
  #expect(try await count(".tool-issue") == 1)
  #expect(try await count(".tool-dev-folder") == 1)
  #expect(try await count(".tools-empty") == 0)
  // 权限按风险排好：exec（高）在前，network（中），clipboard.write（低）。
  #expect(try await evaluate(
    "[...document.querySelectorAll('[data-plugin-id=\"com.example.jwt\"] .tool-permission')].map(n => n.dataset.risk + ':' + n.dataset.granted).join(',')",
    in: webView) == "high:false,medium:false,low:true")
  // 卸载只给用户安装的插件；开发插件给「移除开发目录」；内置原生工具没有「在 Finder 中显示」。
  #expect(try await count("[data-plugin-id=\"com.example.jwt\"] .action-button.danger") == 1)
  #expect(try await count("[data-plugin-id=\"com.example.dev\"] .action-button.danger") == 0)
  #expect(try await count("[data-plugin-id=\"com.example.dev\"] .tool-plugin-actions .action-button") == 2)
  #expect(try await count("[data-plugin-id=\"aster.builtin\"] .tool-plugin-actions") == 0)
  // Quick Terminal 占用了 ⌃⌥Space：工具面板这一项禁用并注明。
  let option = "document.querySelector('[data-setting-key=\"tools.launcherShortcut\"] option[value=\"controlOptionSpace\"]')"
  #expect(try await evaluate("String(\(option)?.disabled)", in: webView) == "true")
  #expect(try await evaluate("\(option)?.textContent ?? ''", in: webView).contains("已被 Quick Terminal 使用"))

  // 搜索能找到插件管理里的条目，点击后跳回工具页。
  _ = try await evaluate(
    "const s = document.getElementById('settings-search'); s.value = '开发目录'; s.dispatchEvent(new Event('input')); 'ok'",
    in: webView)
  #expect(try await evaluate(
    "[...document.querySelectorAll('.search-result-section')].some(n => n.textContent.startsWith('工具')) ? 'yes' : 'no'",
    in: webView) == "yes")
}
