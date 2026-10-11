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
  #expect(text.string == document)
  #expect(scroll.contentSize.width > 100)
  #expect(scroll.contentSize.height > 100)
  #expect(text.frame.width >= scroll.contentSize.width)
  #expect(layout.glyphRange(forBoundingRect: text.visibleRect, in: container).length > 0)
  if !softWrap { #expect(text.frame.width > scroll.contentSize.width) }
  #expect(text.frame.height > scroll.contentSize.height)
  text.scrollRangeToVisible(NSRange(location: (document as NSString).length - 1, length: 1))
  #expect(text.visibleRect.origin.y > 0)
  window.setContentSize(NSSize(width: 900, height: 620))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(text.frame.width >= scroll.contentSize.width)
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
