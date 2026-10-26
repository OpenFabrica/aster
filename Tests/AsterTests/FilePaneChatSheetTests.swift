// 文件发送对话框的复制与预览选文验证，使用隔离剪贴板。
import AppKit
import AsterCore
import Combine
import Testing
import WebKit

@testable import Aster

@MainActor
private func chatDescendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(chatDescendants)
}

@Test("文件聊天对话框复制当前选区与文件引用，不读磁盘全文")
@MainActor
func fileChatSheetCopiesFrozenSelectionToIsolatedPasteboard() async throws {
  let (model, controller, _, url) = try filePaneTestFixture("disk only")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let pane = try #require(model.selectedTab?.activePaneID)
  let context = FileChatContext(path: url.path, selection: "unsaved selection", lines: 2...3)
  let presentation = AgentChatPresentation(originPaneID: pane, destinations: [],
    selection: context.selection, transcript: "", transcriptHasError: false, fileContext: context)
  let clipboard = NSPasteboard(name: .init("FileChatTests.\(UUID().uuidString)"))
  defer { clipboard.releaseGlobally() }
  let sheet = AgentChatSendSheetController(model: model, presentation: presentation, pasteboard: clipboard)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.orderFront(nil)
  defer { if let attached = window.attachedSheet { window.endSheet(attached) }; window.orderOut(nil) }
  sheet.present(on: window) {}
  let panel = try #require(window.attachedSheet?.contentView)
  panel.layoutSubtreeIfNeeded()
  let preview = try #require(chatDescendants(panel).compactMap { $0 as? NSTextView }.first { !$0.isEditable })
  let scroll = try #require(preview.enclosingScrollView)
  scroll.tile()
  let container = try #require(preview.textContainer)
  #expect(preview.frame.width >= scroll.contentSize.width)
  #expect(try #require(preview.layoutManager).glyphRange(forBoundingRect: preview.visibleRect, in: container).length > 0)
  let title = try #require(chatDescendants(panel).compactMap { $0 as? NSTextField }.first { $0.stringValue == L("发送文件到 Chat") })
  #expect(abs(title.convert(title.bounds, to: panel).minX - 28) <= 3)
  let copy = try #require(chatDescendants(panel).compactMap { $0 as? NSButton }.first { $0.title == "Copy Message" })
  copy.performClick(nil)
  let message = try #require(clipboard.string(forType: .string))
  #expect(message.contains(url.path))
  #expect(message.contains("Lines: 2-3"))
  #expect(message.contains("unsaved selection"))
  #expect(!message.contains("disk only"))
  #expect(model.selectedTab?.activePaneID == pane)
  if let path = ProcessInfo.processInfo.environment["ASTER_FILE_PANE_EVIDENCE_DIR"] {
    let target = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let bitmap = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
    panel.cacheDisplay(in: panel.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: target.appendingPathComponent("file-chat-sheet.png"))
  }
}

@Test("预览 Send to Chat 捕获渲染后的选文")
@MainActor
func filePreviewChatCapturesRenderedSelection() async throws {
  let (model, controller, _, url) = try filePaneTestFixture("**Rendered selection**", extension: "md")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let mode = try #require(chatDescendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
  mode.selectedSegment = 1
  mode.sendAction(mode.action, to: mode.target)
  let web = try #require(controller.previewWebView)
  var selected = ""
  for _ in 0..<100 {
    selected = (try? await web.evaluateJavaScript("""
      (() => { const p = document.querySelector('p'); if (!p) return '';
      const r = document.createRange(); r.selectNodeContents(p);
      const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); return s.toString(); })()
      """) as? String) ?? ""
    if selected == "Rendered selection" { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(selected == "Rendered selection")
  var presentation: AgentChatPresentation?
  let subscription = model.agentChatPresentationRequested.sink { presentation = $0 }
  defer { subscription.cancel() }
  let button = try #require(chatDescendants(controller.view).compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "file-pane-send-to-chat" })
  button.performClick(nil)
  for _ in 0..<100 {
    if presentation != nil { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(presentation?.selection == "Rendered selection")
  #expect(presentation?.fileContext?.path == url.path)
}
