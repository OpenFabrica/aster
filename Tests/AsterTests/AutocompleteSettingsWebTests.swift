// 使用实际设置网页检验恢复出的模态选择、更新反馈与桥消息，不触碰用户学习数据。
import AppKit
import AsterCore
import Testing
import WebKit

@testable import Aster

@MainActor
private final class AutocompleteSettingsPage: NSObject, WKScriptMessageHandler {
  let web: WKWebView
  var messages: [[String: Any]] = []

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 850), configuration: configuration)
    super.init()
    configuration.userContentController.add(self, name: "asterSettings")
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if let message = message.body as? [String: Any], message["kind"] as? String != "ready" {
      messages.append(message)
    }
  }

  func close() { web.configuration.userContentController.removeScriptMessageHandler(forName: "asterSettings") }

  @discardableResult
  func evaluate(_ script: String) async throws -> String {
    try await web.evaluateJavaScript(script) as? String ?? ""
  }

  func wait(_ expression: String) async throws {
    for _ in 0..<150 {
      if try await evaluate("String(Boolean(\(expression)))") == "true" { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("自动补全设置页面未达到预期状态：\(expression)")
  }

  func open() async throws {
    let directory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/settings-ui")
    web.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
    try await wait("window.AsterSettings")
    try await evaluate("""
      window.autocompleteFixture = {revision:1,values:{
        'controls.autocompleteShortcut':'tab','controls.autocompleteCandidatePanel':'escape',
        'controls.autocompleteInlineSuggestion':true,'controls.autocompleteOnDeviceLearning':true,
        'controls.autocompleteSkipSecrets':false,'controls.autocompleteCompletionStatus':{state:'idle'}
      },capabilities:{},themes:[],agents:[]};
      window.AsterSettings.receive({type:'snapshot',snapshot:window.autocompleteFixture});
      window.AsterSettings.receive({type:'selectSection',section:'controls'}); ''
      """)
    try await wait("document.querySelector('[data-setting-key=clearAutocomplete] button')")
    messages.removeAll()
  }

  func openClear() async throws {
    try await evaluate("document.querySelector('[data-setting-key=clearAutocomplete] button').click(); ''")
  }

  func status(_ value: String) async throws {
    try await evaluate("window.AsterSettings.receive({type:'autocompleteStatus',status:\(value)}); ''")
  }

  /// 可选真实 WebKit 截图证据，窗口与数据均为测试专用。
  func capture(_ name: String) async throws {
    guard let path = ProcessInfo.processInfo.environment["ASTER_AUTOCOMPLETE_UI_EVIDENCE_DIR"] else { return }
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web
    window.appearance = NSAppearance(named: .aqua)
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(80))
    let image: NSImage? = try await withCheckedThrowingContinuation { continuation in
      web.takeSnapshot(with: nil) { image, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: image) }
      }
    }
    let tiff = try #require(image?.tiffRepresentation)
    let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
  }
}

@Test("清理弹窗默认空选，取消和遮罩无请求，确认只发送勾选的五类布尔值")
@MainActor
func autocompleteClearDialogUsesExplicitEmptySelection() async throws {
  let page = AutocompleteSettingsPage()
  defer { page.close() }
  try await page.open()
  try await page.openClear()
  try await page.capture("autocomplete-clear-empty")
  #expect(try await page.evaluate("String(document.querySelectorAll('.autocomplete-clear-choice input').length)") == "5")
  #expect(try await page.evaluate("String(document.querySelectorAll('.autocomplete-clear-choice input:checked').length)") == "0")
  #expect(try await page.evaluate("String(document.querySelector('.autocomplete-clear-confirm').disabled)") == "true")
  try await page.evaluate("document.querySelector('.autocomplete-clear-choice input').click(); document.querySelector('.autocomplete-clear-overlay').click(); ''")
  #expect(page.messages.isEmpty)
  try await page.openClear()
  #expect(try await page.evaluate("String(document.querySelector('.autocomplete-clear-confirm').disabled)") == "true")
  try await page.evaluate("document.querySelector('.autocomplete-clear-dialog .settings-dialog-actions button').click(); ''")
  #expect(page.messages.isEmpty)
  try await page.openClear()
  try await page.evaluate("""
    document.querySelector('input[name=history]').click();
    document.querySelector('input[name=learnedSpecs]').click();
    document.querySelector('.autocomplete-clear-confirm').click(); ''
    """)
  for _ in 0..<50 where page.messages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
  let action = try #require(page.messages.last)
  #expect(action["action"] as? String == "clearAutocomplete")
  let payload = try #require(action["payload"] as? [String: Bool])
  #expect(payload == ["history": true, "fullLines": false, "helpProbe": false, "learnedFolder": false, "learnedSpecs": true])
  #expect(try await page.evaluate("String(Boolean(document.querySelector('.autocomplete-clear-dialog')))") == "false")
}

@Test("数据库运行态原位显示钳制进度，失败恢复按钮，空数据及相对时间遵循原版规则")
@MainActor
func autocompleteDatabaseStatusTransitionsInPlace() async throws {
  let page = AutocompleteSettingsPage()
  defer { page.close() }
  try await page.open()
  #expect(try await page.evaluate("document.querySelector('[data-setting-key=updateAutocomplete] .setting-detail').textContent") == "尚无数据")
  for (input, expected) in [("-3", "0"), ("0.315", "0.315"), ("5", "1")] {
    try await page.status("{state:'running',progress:\(input)}")
    #expect(try await page.evaluate("document.querySelector('[role=progressbar]').getAttribute('aria-valuenow')") == expected)
    #expect(try await page.evaluate("String(Boolean(document.querySelector('[data-setting-key=updateAutocomplete] button')))") == "false")
  }
  try await page.status("{state:'failure',message:'<b>download failed</b>'}")
  #expect(try await page.evaluate("document.querySelector('[data-setting-key=updateAutocomplete] .setting-detail').textContent") == "<b>download failed</b>")
  #expect(try await page.evaluate("String(document.querySelector('[data-setting-key=updateAutocomplete] button').disabled)") == "false")
  try await page.status("{state:'idle',currentDate:'2026-10-05',specCount:711,lastCheckedAt:'invalid-date'}")
  #expect(try await page.evaluate("document.querySelector('[data-setting-key=updateAutocomplete] .setting-detail').textContent") == "v2026-10-05 · 711 条命令 · 上次检查于 invalid-date")
  #expect(try await page.evaluate("JSON.stringify([0,59000,60000,3600000,86400000].map(delta=>AsterAutocompleteSettings.relativeTime(new Date(100000000-delta).toISOString(),100000000)))") == "[\"just now\",\"just now\",\"1m ago\",\"1h ago\",\"1d ago\"]")
  try await page.evaluate("document.querySelector('[data-setting-key=updateAutocomplete] button').click(); ''")
  for _ in 0..<50 where page.messages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
  #expect(page.messages.last?["action"] as? String == "updateAutocomplete")
  #expect(page.messages.last?["payload"] as? [String: Bool] == [:])
  #expect(try await page.evaluate("String(document.querySelector('[data-setting-key=updateAutocomplete] button').disabled)") == "false")
}

@Test("恢复五种接受键与四种面板模式，学习分组和同步能力控制清理入口")
@MainActor
func autocompleteSettingsRecoveredOptionsAndCapability() async throws {
  let page = AutocompleteSettingsPage()
  defer { page.close() }
  try await page.open()
  try await page.status("{state:'idle',currentDate:'2026-10-05',specCount:711}")
  try await page.capture("autocomplete-settings")
  #expect(try await page.evaluate("JSON.stringify([...document.querySelectorAll('[data-setting-key=\"controls.autocompleteShortcut\"] option')].map(o=>o.value))") == "[\"tab\",\"tab+right-arrow\",\"right-arrow\",\"ctrl+space\",\"disable\"]")
  #expect(try await page.evaluate("document.querySelector('[data-setting-key=\"controls.autocompleteCandidatePanel\"] option[value=\"option-escape\"]').textContent") == "Option+Escape / F5")
  #expect(try await page.evaluate("JSON.stringify([...document.querySelectorAll('.autocomplete-subheading')].map(x=>x.textContent))") == "[\"建议\",\"学习\"]")
  #expect(try await page.evaluate("String(Boolean(document.querySelector('[data-setting-key=\"controls.clipboardSuggestion\"]')))") == "false")
  try await page.evaluate("""
    autocompleteFixture.values['shell.shellIntegration']=false;
    AsterSettings.receive({type:'snapshot',snapshot:autocompleteFixture});
    const toggle=document.querySelector('[data-setting-key="controls.autocompleteInlineSuggestion"] input');
    toggle.checked=false; toggle.dispatchEvent(new Event('change'));
    toggle.checked=true; toggle.dispatchEvent(new Event('change')); ''
    """)
  #expect(try await page.evaluate("document.querySelector('.toast').textContent") == "此功能需要 Shell 集成。请在 Shell 设置中启用。")
  #expect(try await page.evaluate("String(autocompleteFixture.values['shell.shellIntegration'])") == "false")
  for _ in 0..<50 where page.messages.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
  #expect(page.messages.last?["kind"] as? String == "set")
  try await page.evaluate("autocompleteFixture.capabilities.dataSync=true; AsterSettings.receive({type:'snapshot',snapshot:autocompleteFixture}); ''")
  #expect(try await page.evaluate("String(Boolean(document.querySelector('[data-setting-key=clearAutocomplete]')))") == "false")
}

@Test("清理桥拒绝缺项、附加项与数字，空选择保持空且五类彼此独立")
@MainActor
func autocompleteClearBridgeValidatesExactBooleanPayload() throws {
  let empty: [String: Any] = ["history": false, "fullLines": false, "helpProbe": false, "learnedFolder": false, "learnedSpecs": false]
  #expect(try SettingsViewController.autocompleteClearSelection(empty).isEmpty)
  var missing = empty
  missing.removeValue(forKey: "helpProbe")
  #expect(throws: (any Error).self) { try SettingsViewController.autocompleteClearSelection(missing) }
  var extra = empty
  extra["folders"] = true
  #expect(throws: (any Error).self) { try SettingsViewController.autocompleteClearSelection(extra) }
  var numeric = empty
  numeric["history"] = 1
  #expect(throws: (any Error).self) { try SettingsViewController.autocompleteClearSelection(numeric) }
  var selected = empty
  selected["helpProbe"] = true
  #expect(try SettingsViewController.autocompleteClearSelection(selected) == .helpProbe)
}
