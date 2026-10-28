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

@Test("设置页「工具」分类渲染视图控制：徽章、位置下拉、启用开关与不生效提示，操作发出对应动作")
@MainActor
func settingsToolsPageRendersViewControls() async throws {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [
    toolSummary(
      "com.example.views", name: "视图插件",
      views: [
        toolViewSummary("branch", slot: .tabTop),
        toolViewSummary("status", title: "Git 状态", kind: .panel, slot: .inspectorPanel, defaultSlot: .inspectorPanel, enabled: false, inactiveReason: .disabled),
        toolViewSummary("future", title: "未来", slot: .windowTop, defaultSlot: .windowTop, inactiveReason: .unsupported),
      ]),
    toolSummary("com.example.plain", name: "没有视图"),
  ]
  let preferences = isolatedToolsPreferences()
  let bridge = SettingsToolsBridge(preferences: preferences, tools: tools)
  let controller = SettingsViewController(preferences: preferences, updateController: nil, toolsBridge: bridge)
  controller.loadViewIfNeeded()
  let webView = try #require(controller.settingsWebViewForTesting)

  #expect(try await poll("String(document.querySelectorAll('.nav-item').length)", until: "12", in: webView) == "12")
  _ = try await evaluate("document.querySelector('[data-section=\"tools\"]')?.click(); 'ok'", in: webView)
  #expect(try await poll("document.querySelector('.page-title')?.textContent ?? ''", until: "工具", in: webView) == "工具")

  func eval(_ script: String) async throws -> String { try await evaluate(script, in: webView) }
  // 只有声明了视图的插件才有「视图」一栏。
  #expect(try await eval("String(document.querySelectorAll('.tool-view').length)") == "3")
  #expect(try await eval("String(document.querySelectorAll('[data-plugin-id=\"com.example.plain\"] .tool-view').length)") == "0")
  #expect(try await eval("[...document.querySelectorAll('.tool-view')].map(n => n.dataset.viewId).join(',')") == "branch,status,future")
  // 类型徽章。
  #expect(try await eval("[...document.querySelectorAll('.tool-view .tool-badge')].map(n => n.dataset.kind).join(',')") == "bar,panel,bar")
  // bar 只能选 tab.top / tab.bottom；当前值是 tab.top；缺省位置（tab.bottom）带「（默认）」后缀。
  let branch = "document.querySelector('[data-view-id=\"branch\"] select')"
  #expect(try await eval("[...\(branch).options].map(o => o.value).join(',')") == "tab.top,tab.bottom,pane.bottom")
  #expect(try await eval("\(branch).value") == "tab.top")
  #expect(try await eval("[...\(branch).options].find(o => o.value === 'tab.bottom').textContent").hasSuffix("（默认）"))
  // 声明了未实现位置的视图，下拉框补一项当前值，并带灰字提示。
  #expect(try await eval("document.querySelector('[data-view-id=\"future\"] select').value") == "window.top")
  #expect(try await eval("document.querySelector('[data-view-id=\"future\"] .tool-view-hint')?.textContent ?? ''") == "本版本暂不支持这个位置")
  #expect(try await eval("String(document.querySelector('[data-view-id=\"status\"] input[type=checkbox]').checked)") == "false")

  // 改位置：选回缺省位置发 null，其余发位置 id。
  _ = try await eval("const s = \(branch); s.value = 'tab.bottom'; s.dispatchEvent(new Event('change')); 'ok'")
  for _ in 0..<150 where tools.viewSlotCalls.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
  #expect(tools.viewSlotCalls.count == 1)
  #expect(tools.viewSlotCalls.first?.view == "branch" && tools.viewSlotCalls.first?.slot == nil)
  // 开关。
  _ = try await eval("const c = document.querySelector('[data-view-id=\"status\"] input[type=checkbox]'); c.checked = true; c.dispatchEvent(new Event('change')); 'ok'")
  for _ in 0..<150 where tools.viewEnabledCalls.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
  #expect(tools.viewEnabledCalls.count == 1)
  #expect(tools.viewEnabledCalls.first?.view == "status" && tools.viewEnabledCalls.first?.enabled == true)
}
