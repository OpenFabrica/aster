import AppKit
import AsterCore
import Testing
import WebKit
@testable import Aster

@Test("文件工具栏显示保存状态和只读状态，预览缩放不改变源码字号")
@MainActor
func filePaneToolbarTracksEditingAndPreviewZoom() async throws {
  let (model, controller, preferences, url) = try filePaneTestFixture("<svg><text>toolbar</text></svg>", extension: "svg")
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.orderFront(nil)
  defer { window.orderOut(nil); model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let toolbar = try #require(fileMenuDescendants(controller.view).compactMap { $0 as? FilePaneToolbar }.first)
  let source = try #require(controller.sourceTextView)
  let runtime = try #require(model.selectedTab?.activeRuntime)
  func button(_ id: String) throws -> NSButton {
    try #require(fileMenuDescendants(toolbar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id })
  }
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(toolbar.bounds.height == 32)
  #expect(toolbar.zoom.isHidden)
  #expect(try button("file-pane-save").isHidden)
  #expect(try !button("file-pane-saved").isHidden)
  #expect(try !button("file-pane-close").isHidden)
  runtime.updateDocument("# edited toolbar")
  #expect(try !button("file-pane-save").isHidden)
  #expect(try !button("file-pane-discard").isHidden)
  #expect(try button("file-pane-close").isHidden)
  try button("file-pane-save").performClick(nil)
  #expect(!runtime.isDirty)
  #expect(try String(contentsOf: url, encoding: .utf8) == "# edited toolbar")
  #expect(try button("file-pane-save").isHidden)
  let mode = try #require(fileMenuDescendants(toolbar).compactMap { $0 as? NSSegmentedControl }.first)
  mode.selectedSegment = 1
  mode.sendAction(mode.action, to: mode.target)
  #expect(!toolbar.zoom.isHidden)
  #expect(try button("file-pane-saved").isHidden)
  toolbar.selectZoom(1.5)
  let web = try #require(controller.previewWebView)
  #expect(web.magnification == 1.5)
  mode.selectedSegment = 0
  mode.sendAction(mode.action, to: mode.target)
  #expect(toolbar.zoom.isHidden)
  #expect(source.font?.pointSize == preferences.terminalFontVariants.normal.pointSize)
  preferences.configuration.editor.lineWrap = false
  for _ in 0..<5 { await Task.yield() }
  #expect(source.enclosingScrollView?.hasHorizontalScroller == true)
  runtime.setReadOnly(true)
  #expect(try button("file-pane-saved").isHidden)
}

@Test("窄文件 Pane 保留可用图标动作且不溢出", arguments: [260.0, 680.0])
@MainActor
func filePaneToolbarUsesCompactIconsWithoutOverflow(width: Double) throws {
  let mode = FilePresentationControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
  mode.setImage(NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil), forSegment: 0)
  mode.setImage(NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil), forSegment: 1)
  mode.selectedSegment = 0
  let bar = FilePaneToolbar(mode: mode, send: {}, open: {}, save: {}, discard: {}, run: {}, close: {})
  bar.showZoom(false)
  bar.runButton.isHidden = true
  bar.update(editable: true, dirty: true, statusText: nil)
  bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(width, 400), height: 100),
    styleMask: [.titled], backing: .buffered, defer: false)
  let root = NSView()
  window.contentView = root
  root.addSubview(bar)
  bar.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
    bar.widthAnchor.constraint(equalToConstant: width), bar.topAnchor.constraint(equalTo: root.topAnchor)])
  window.orderFront(nil)
  defer { window.orderOut(nil) }
  root.layoutSubtreeIfNeeded()
  root.layoutSubtreeIfNeeded()
  #expect(abs(bar.bounds.width - width) < 0.01)
  let save = try #require(fileMenuDescendants(bar).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "file-pane-save" })
  #expect(save.imagePosition == (width < 280 ? .imageOnly : .imageLeading))
  for button in fileMenuDescendants(bar).compactMap({ $0 as? NSButton }) where !button.isHiddenOrHasHiddenAncestor {
    let rect = button.convert(button.bounds, to: bar)
    #expect(rect.width >= 22)
    #expect(rect.minX >= 0)
    #expect(rect.maxX <= bar.bounds.maxX)
    if width >= 280 && button.imagePosition == .imageLeading && !button.title.isEmpty {
      #expect(button.bounds.width + 0.01 >= ceil(button.attributedTitle.size().width) + 24)
    }
  }
  if let path = ProcessInfo.processInfo.environment["ASTER_FILE_PANE_EVIDENCE_DIR"] {
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bitmap = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
    bar.cacheDisplay(in: bar.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:]))
      .write(to: directory.appendingPathComponent("toolbar-dirty-\(Int(width)).png"))
  }
}

@Test("文件 Run 在新终端执行磁盘脚本，保留未保存稿与原 Pane")
@MainActor
func filePaneRunUsesDiskScriptInNewTerminal() async throws {
  let (model, controller, preferences, url) = try filePaneTestFixture("printf DISK_RUN", extension: "sh")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let original = try #require(model.selectedTab)
  let runtime = try #require(original.activeRuntime)
  runtime.updateDocument("printf UNSAVED_RUN")
  let run = try #require(fileMenuDescendants(controller.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "file-pane-run" })
  #expect(!run.isHidden)
  run.performClick(nil)
  let target = try #require(model.selectedTab)
  #expect(target !== original)
  #expect(target.workingDirectory == url.deletingLastPathComponent().path)
  #expect(runtime.documentText == "printf UNSAVED_RUN")
  #expect(runtime.isDirty)
  let session = try #require(target.activeSession)
  let terminal = try liveGhosttyView(for: session, preferences: preferences)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = terminal.superview
  window.orderFront(nil)
  defer { window.orderOut(nil) }
  for _ in 0..<250 {
    if session.shellIntegrationDetected { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(session.shellIntegrationDetected)
  model.startPendingRecipeCommands(paneID: target.activePaneID)
  var output = ""
  for _ in 0..<100 {
    output = session.textSnapshot().lines.joined(separator: "\n")
    if output.contains("DISK_RUN") { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(output.contains("DISK_RUN"))
  #expect(!output.contains("UNSAVED_RUN"))
  #expect(runtime.isDirty)
}
