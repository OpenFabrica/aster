// 文件 Pane 的可见源码布局回归，使用临时文件和隔离偏好。
import AppKit
import AsterCore
import Foundation
import Testing
@testable import Aster

@Test("Files 打开或从预览切回源码时显示可见字形", arguments: [PaneKind.editor, .preview], [true, false])
@MainActor
func filePaneSourceHasVisibleGlyphsInViewport(kind: PaneKind, softWrap: Bool) async throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneLayoutTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("aster-pane-layout-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("example.md")
  let source = "# 中文源码显示验收\n\nSource content should stay visible.\n\n```swift\nlet answer = 42\n```\n"
  let document = source + String(repeating: "long-source-line ", count: 80) + "\n"
    + (0..<80).map { "let row\($0) = \($0)" }.joined(separator: "\n")
  try Data(document.utf8).write(to: file)
  let descriptor = PaneDescriptor(kind: kind, workingDirectory: root.path, resourcePath: file.path)
  let model = AppModel(defaults: defaults)
  model.openResourceInNewTab(descriptor)
  let preferences = AppPreferences(defaults: defaults)
  var configuration = preferences.configuration
  configuration.editor.lineWrap = softWrap
  preferences.importConfiguration(configuration)
  preferences.inspectorPresented = true
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  workspace.loadViewIfNeeded()
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = workspace
  window.setContentSize(NSSize(width: 1180, height: 760))
  window.orderFront(nil)
  defer { window.close() }
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(500))
  let controller = try #require(workspace.children.compactMap { $0 as? FilePaneViewController }.first)
  let mode = try #require(filePaneDescendant(NSSegmentedControl.self, in: controller.view))
  if mode.selectedSegment == 1 {
    mode.selectedSegment = 0
    mode.sendAction(mode.action, to: mode.target)
  }
  try await Task.sleep(for: .milliseconds(250))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(controller.parent === workspace)
  let text = try #require(controller.sourceTextView)
  let scroll = try #require(text.enclosingScrollView)
  let container = try #require(text.textContainer)
  let layout = try #require(text.layoutManager)
  func viewportWidth() -> CGFloat {
    // 原生 ruler 占据负 x 的 inset；正文只需覆盖从 x=0 开始的实际可见区域。
    let visible = scroll.contentView.bounds
    return max(0, visible.maxX - max(0, visible.minX))
  }
  #expect(text.string == document)
  #expect(scroll.contentSize.width > 100)
  #expect(scroll.contentSize.height > 100)
  #expect(text.frame.width >= viewportWidth())
  #expect(layout.glyphRange(forBoundingRect: text.visibleRect, in: container).length > 0)
  if !softWrap { #expect(text.frame.width > viewportWidth()) }
  #expect(text.frame.height > scroll.contentSize.height)
  text.scrollRangeToVisible(NSRange(location: (document as NSString).length - 1, length: 1))
  #expect(text.visibleRect.origin.y > 0)
  window.setContentSize(NSSize(width: 900, height: 620))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(text.frame.width >= viewportWidth())
  #expect(text.frame.height >= scroll.contentSize.height)
  #expect(layout.glyphRange(forBoundingRect: text.visibleRect, in: container).length > 0)
}

@MainActor
private func filePaneDescendant<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
  if let view = root as? View { return view }
  for child in root.subviews {
    if let view = filePaneDescendant(type, in: child) { return view }
  }
  return nil
}

@Test("切回含 JSON 文件 Pane 的分屏标签后，源码用 TextKit 1 且正文按 Pane 实际宽度排版")
@MainActor
func filePaneSourceLayoutIsStableAfterTabSwitch() async throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneLayoutTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("aster-pane-tab-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("report.json")
  let items = (0..<200).map { index in
    "    {\n      \"title\": \"月之暗面发布 Kimi K3.1 Pro 第\(index)条\",\n      \"summary\": \""
      + String(repeating: "AI 模型在数学领域的突破源于深度优先搜索与自动验证器的结合。", count: 3) + "\"\n    }"
  }
  try Data(("{\n  \"flashes\": [\n" + items.joined(separator: ",\n") + "\n  ]\n}\n").utf8).write(to: file)
  let plain = WorkspaceTabSnapshot(id: UUID(), title: "Plain",
    layout: .leaf(PaneDescriptor(kind: .fileBrowser, workingDirectory: root.path)))
  let split = WorkspaceTabSnapshot(id: UUID(), title: "Split", layout: .split(axis: .horizontal,
    first: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: root.path)),
    second: .leaf(PaneDescriptor(kind: .editor, workingDirectory: root.path, resourcePath: file.path)), ratio: 0.5))
  defaults.set(try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: plain.id, tabs: [plain, split])),
    forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let preferences = AppPreferences(defaults: defaults)
  var configuration = preferences.configuration
  configuration.editor.lineWrap = true
  preferences.importConfiguration(configuration)
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 760),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = workspace
  window.orderFront(nil)
  defer { window.close() }
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(200))
  model.select(try #require(model.tabs.first { $0.id == split.id }))
  try await Task.sleep(for: .milliseconds(300))
  window.contentView?.layoutSubtreeIfNeeded()
  let text = try #require(workspace.children.compactMap { $0 as? FilePaneViewController }.last?.sourceTextView)
  let scroll = try #require(text.enclosingScrollView)
  let container = try #require(text.textContainer)
  let visible = scroll.contentView.bounds
  let viewport = max(0, visible.maxX - max(0, visible.minX))
  #expect(text.textLayoutManager == nil)
  #expect(viewport > 400)
  #expect(abs(text.frame.width - viewport) < 1)
  #expect(abs(container.containerSize.width - (viewport - text.textContainerInset.width * 2)) < 1)
}

@Test("文件 Pane 刚创建、尚无宽度时，源码已是 TextKit 1 且不按零宽排版")
@MainActor
func filePaneSourceStartsWithTextKit1AndPositiveContainer() throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneLayoutTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("aster-pane-fresh-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("report.json")
  try Data(("{\n" + (0..<200).map { "  \"key\($0)\": \"月之暗面发布 Kimi K3.1 Pro，性能逼近 Claude\"" }
    .joined(separator: ",\n") + "\n}\n").utf8).write(to: file)
  let descriptor = PaneDescriptor(kind: .editor, workingDirectory: root.path, resourcePath: file.path)
  let tab = TerminalTabItem(title: "report.json", workingDirectory: root.path, layout: .leaf(descriptor))
  let preferences = AppPreferences(defaults: defaults)
  var configuration = preferences.configuration
  configuration.editor.lineWrap = true
  preferences.importConfiguration(configuration)
  let controller = FilePaneViewController(runtime: try #require(tab.activeRuntime), tab: tab,
    model: AppModel(defaults: defaults), preferences: preferences)
  controller.loadViewIfNeeded()
  let text = try #require(controller.sourceTextView)
  // TextKit 2 视图被行号标尺访问 layoutManager 时会中途切换到 TextKit 1，切换前按零宽排出的旧折行会残留。
  #expect(text.textLayoutManager == nil)
  #expect(try #require(text.textContainer).containerSize.width > 0)
  // 零宽排版会把每个字符折成一行，文本视图被撑到上万点高。
  #expect(text.frame.height < 10_000)
}
