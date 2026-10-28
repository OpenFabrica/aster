import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 在临时目录写一张指定像素尺寸的 PNG。
private func writePNG(_ url: URL, width: Int, height: Int) throws {
  let rep = try #require(NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0))
  try #require(rep.representation(using: .png, properties: [:])).write(to: url)
}

/// 在视图树里找第一个指定类型的子视图。
@MainActor
private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
  if let match = root as? T { return match }
  for child in root.subviews {
    if let match = firstSubview(of: type, in: child) { return match }
  }
  return nil
}

/// 轮询等待条件成立，最多 2 秒；后台解码完成前不能直接断言。
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Test("文件浏览器打开图片目录时选中第一张图并预览，↓ 切到下一张")
@MainActor
func fileBrowserPreviewsImagesAndArrowKeySwitches() async throws {
  _ = NSApplication.shared
  let suite = "AsterFileBrowserPreviewTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-browser-preview-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  try Data("notes\n".utf8).write(to: root.appendingPathComponent("a-notes.txt"))
  try writePNG(root.appendingPathComponent("b-first.png"), width: 40, height: 20)
  try writePNG(root.appendingPathComponent("c-second.png"), width: 30, height: 60)

  let descriptor = PaneDescriptor(kind: .fileBrowser, workingDirectory: root.path, resourcePath: root.path)
  let tab = TerminalTabItem(title: "images", workingDirectory: root.path, layout: .leaf(descriptor))
  let runtime = try #require(tab.activeRuntime)
  let controller = FileBrowserViewController(runtime: runtime, tab: tab, model: AppModel(defaults: defaults))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  window.contentView = controller.view
  window.layoutIfNeeded()

  let preview = try #require(firstSubview(of: FileBrowserImagePreview.self, in: controller.view))
  // 文本文件排在前面，但打开目录时应直接选中第一张图片。
  #expect(preview.url?.lastPathComponent == "b-first.png")
  #expect(!preview.isHidden)
  #expect(preview.frame.height > 0)
  try await waitUntil { preview.displayedImage != nil }
  #expect(preview.displayedImage != nil)
  #expect(preview.caption.contains("40 × 20"))

  let table = try #require(controller.preferredKeyView as? NSTableView)
  #expect(window.makeFirstResponder(table))
  let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: window.windowNumber, context: nil,
    characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
    charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
    isARepeat: false, keyCode: 125))
  table.keyDown(with: down)
  #expect(preview.url?.lastPathComponent == "c-second.png")
  try await waitUntil { preview.caption.contains("30 × 60") }
  #expect(preview.caption.contains("30 × 60"))

  // 选中非图片时收起预览，列表占满。
  table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  window.layoutIfNeeded()
  #expect(preview.isHidden)
  #expect(preview.url == nil)
}

@Test("以 Editor 打开图片时直接显示图片预览，而不是空的源码视图")
@MainActor
func filePaneOpensImageAsPreviewEvenInEditorMode() throws {
  _ = NSApplication.shared
  let suite = "AsterFilePaneImageEditorTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-pane-image-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("shot.png")
  try writePNG(file, width: 16, height: 16)
  let descriptor = PaneDescriptor(kind: .editor, workingDirectory: root.path, resourcePath: file.path)
  let tab = TerminalTabItem(title: "shot.png", workingDirectory: root.path, layout: .leaf(descriptor))
  let runtime = try #require(tab.activeRuntime)
  let controller = FilePaneViewController(runtime: runtime, tab: tab,
    model: AppModel(defaults: defaults), preferences: AppPreferences(defaults: defaults))
  controller.loadViewIfNeeded()

  #expect(controller.sourceTextView == nil)
  #expect(firstSubview(of: NSImageView.self, in: controller.view)?.image != nil)
}
