// 文件 Pane 主题、编辑器行号和发送当前选区的行为回归。
import AppKit
import AsterCore
import Combine
import Testing
import WebKit

@testable import Aster

@MainActor
func filePaneTestFixture(_ text: String, extension suffix: String = "txt", mode: WorkspaceResourceOpenMode = .edit) throws
  -> (AppModel, FilePaneViewController, AppPreferences, URL)
{
  let defaults = UserDefaults(suiteName: "FilePaneThemeTests.\(UUID().uuidString)")!
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
  try text.write(to: url, atomically: true, encoding: .utf8)
  #expect(model.openResource(url, mode: mode, placement: .split(.right)))
  let tab = try #require(model.selectedTab)
  let controller = FilePaneViewController(
    runtime: try #require(tab.activeRuntime), tab: tab, model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  return (model, controller, preferences, url)
}

@Test("文件源码行号即时遵循编辑器配置")
@MainActor
func filePaneLineNumbersFollowEditorSetting() async throws {
  let (model, controller, preferences, url) = try filePaneTestFixture("first\nsecond\n")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let scroll = try #require(controller.sourceTextView?.enclosingScrollView)
  #expect(scroll.rulersVisible)
  preferences.configuration.editor.showLineNumbers = false
  for _ in 0..<5 { await Task.yield() }
  #expect(!scroll.rulersVisible)
  preferences.configuration.editor.showLineNumbers = true
  for _ in 0..<5 { await Task.yield() }
  #expect(scroll.rulersVisible)
}

@Test("源码普通文字和预览正文使用当前主题颜色", arguments: ["Ayu Light", "Ayu Dark"])
@MainActor
func filePaneSourceAndPreviewUseThemeForeground(themeName: String) async throws {
  let (model, controller, preferences, url) = try filePaneTestFixture(
    "ordinary words\n\n# Current theme\n\nAster file preview\n\n```swift\nlet answer = 42\n```\n", extension: "md")
  let dark = themeName == "Ayu Dark"
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.setContentSize(NSSize(width: 680, height: 440))
  controller.view.frame = NSRect(x: 0, y: 0, width: 680, height: 440)
  window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  window.orderFront(nil)
  defer {
    window.orderOut(nil)
    preferences.cancelThemePreview()
    model.tabs.forEach { $0.stop(immediately: true) }
    try? FileManager.default.removeItem(at: url)
  }
  preferences.previewTheme(TerminalThemeCatalog.resolve(named: themeName, customThemes: [], mode: dark ? .dark : .light))
  let textView = try #require(controller.sourceTextView)
  let headingLocation = (textView.string as NSString).range(of: "Current theme").location
  for _ in 0..<100 {
    if let actual = textView.textStorage?.attribute(.foregroundColor, at: headingLocation, effectiveRange: nil) as? NSColor,
      HexColor(nsColor: actual) == preferences.activeTheme.palette.ansiColors[4] { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let actual = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
  #expect(actual.map(HexColor.init(nsColor:)) == preferences.activeTheme.palette.foreground)
  let headingColor = textView.textStorage?.attribute(.foregroundColor, at: headingLocation, effectiveRange: nil) as? NSColor
  #expect(headingColor.map(HexColor.init(nsColor:)) == preferences.activeTheme.palette.ansiColors[4])
  func capture(_ mode: String) throws {
    guard let path = ProcessInfo.processInfo.environment["ASTER_FILE_PANE_EVIDENCE_DIR"] else { return }
    window.contentView?.layoutSubtreeIfNeeded()
    controller.view.displayIfNeeded()
    let destination = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:]))
      .write(to: destination.appendingPathComponent("\(dark ? "dark" : "light")-\(mode).png"))
  }
  try capture("source")
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  let mode = try #require(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
  mode.selectedSegment = 1
  mode.sendAction(mode.action, to: mode.target)
  let web = try #require(controller.previewWebView)
  var color = ""
  // 批量窗口测试中 WebKit 可能仍在加载；按正文就绪等待，避免把 about:blank 当作主题结果。
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while ContinuousClock.now < deadline {
    color = (try? await web.evaluateJavaScript("document.body.innerText.includes('ordinary words') ? getComputedStyle(document.body).color : ''") as? String) ?? ""
    if !color.isEmpty { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let fg = preferences.activeTheme.palette.foreground
  let readiness = color.isEmpty ? (try? await web.evaluateJavaScript(
    "JSON.stringify({ready:document.readyState,text:document.body?.textContent,url:location.href})") as? String) : nil
  #expect(color == "rgb(\(fg.red), \(fg.green), \(fg.blue))",
    "Web preview: \(readiness ?? "ready"), loading: \(web.isLoading)")
  if let path = ProcessInfo.processInfo.environment["ASTER_FILE_PANE_EVIDENCE_DIR"] {
    // WebKit 使用独立合成层，NSView.cacheDisplay 无法捕获正文；通过实际 WebKit renderer 截图。
    let image = try await web.takeSnapshot(configuration: nil)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    try #require(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: path).appendingPathComponent("\(dark ? "dark" : "light")-preview.png"))
  }
}

@Test("文件 Send to Chat 捕获当前未保存选区并保留文件焦点")
@MainActor
func filePaneChatUsesCurrentSelectionInsteadOfDiskContents() async throws {
  let (model, controller, _, url) = try filePaneTestFixture("disk contents")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let origin = try #require(model.selectedTab?.activePaneID)
  let runtime = try #require(model.selectedTab?.activeRuntime)
  runtime.updateDocument("unsaved selection")
  let textView = try #require(controller.sourceTextView)
  textView.setSelectedRange(NSRange(location: 8, length: 9))
  var presentation: AgentChatPresentation?
  let subscription = model.agentChatPresentationRequested.sink { presentation = $0 }
  defer { subscription.cancel() }
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  let button = try #require(descendants(controller.view).compactMap { $0 as? NSButton }
    .first { $0.accessibilityLabel() == "Send to Chat" })
  button.performClick(nil)
  for _ in 0..<5 { await Task.yield() }
  #expect(presentation?.selection == "selection")
  #expect(model.selectedTab?.activePaneID == origin)
}
