import AppKit
import AsterCore
import Combine
import Testing
import WebKit
@testable import Aster

@MainActor
private func fileMenuEvent() throws -> NSEvent {
  try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

@Test("源码菜单按文档状态禁用修改并从选区发送 Chat")
@MainActor
func filePaneSourceContextMenuRespectsReadOnlyAndSelection() async throws {
  let (model, controller, _, url) = try filePaneTestFixture("selected source")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let text = try #require(controller.sourceTextView)
  text.setSelectedRange(NSRange(location: 0, length: 8))
  let event = try fileMenuEvent()
  let menu = try #require(text.menu(for: event))
  #expect(Array(menu.items.prefix(3).map(\.title)) == [L("剪切"), L("复制"), L("粘贴")])
  #expect(menu.items.contains { $0.title == L("撤销") })
  #expect(menu.items.contains { $0.title == L("从磁盘重新加载") })
  #expect(!menu.items.contains { $0.title == L("在访达中显示") })
  var sent: AgentChatPresentation?
  let subscription = model.agentChatPresentationRequested.sink { sent = $0 }
  defer { subscription.cancel() }
  let chat = try #require(menu.items.first { $0.title == L("发送到 Chat") + "…" })
  #expect(NSApp.sendAction(try #require(chat.action), to: chat.target, from: chat))
  #expect(sent?.selection == "selected")
  model.selectedTab?.activeRuntime?.setReadOnly(true)
  let locked = try #require(text.menu(for: event))
  #expect(locked.items.first { $0.title == L("剪切") }?.isEnabled == false)
  #expect(locked.items.first { $0.title == L("粘贴") }?.isEnabled == false)
  #expect(locked.items.first { $0.title == L("复制") }?.isEnabled == true)
  #expect(!locked.items.contains { $0.title == L("撤销") || $0.title == L("从磁盘重新加载") })
}

@Test("源码菜单撤销重做修改真实文档，语法选择使用渲染器支持列表")
@MainActor
func filePaneContextUndoRedoAndSyntaxAffectDocument() async throws {
  let (model, controller, _, url) = try filePaneTestFixture("let value = 42", extension: "swift")
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.orderFront(nil)
  defer { window.orderOut(nil); model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let text = try #require(controller.sourceTextView)
  window.makeFirstResponder(text)
  let undo = try #require(text.undoManager)
  undo.groupsByEvent = false
  undo.beginUndoGrouping()
  text.insertText("!", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
  undo.endUndoGrouping()
  let event = try fileMenuEvent()
  func invoke(_ title: String) throws {
    let menu = try #require(text.menu(for: event))
    let item = try #require(menu.items.first { $0.title == title })
    #expect(item.isEnabled)
    #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
  }
  #expect(model.selectedTab?.activeRuntime?.documentText == "let value = 42!")
  try invoke(L("撤销"))
  #expect(text.string == "let value = 42")
  #expect(model.selectedTab?.activeRuntime?.documentText == "let value = 42")
  try invoke(L("重做"))
  #expect(model.selectedTab?.activeRuntime?.documentText == "let value = 42!")
  var syntax: NSMenu?
  for _ in 0..<100 {
    syntax = text.menu(for: event)?.items.first { $0.title == L("语法") }?.submenu
    if syntax?.items.contains(where: { $0.title == "python" }) == true { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect((syntax?.items.count ?? 0) > 50)
  let python = try #require(syntax?.items.first { $0.title == "python" })
  #expect(NSApp.sendAction(try #require(python.action), to: python.target, from: python))
  let selected = text.menu(for: event)?.items.first { $0.title == L("语法") }?.submenu
  #expect(selected?.items.first { $0.title == "python" }?.state == .on)
  #expect(selected?.items.first?.state == .off)
}

@Test("Web 预览保留原生菜单，去重 Chat 并把 Reload 绑定到读盘")
@MainActor
func filePreviewContextMenuPreservesNativeActionsAndReloadsDisk() async throws {
  let (model, controller, _, url) = try filePaneTestFixture("# before", extension: "md")
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let mode = try #require(fileMenuDescendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
  mode.selectedSegment = 1
  mode.sendAction(mode.action, to: mode.target)
  let web = try #require(controller.previewWebView as? FilePreviewWebView)
  let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  let image = NSMenuItem(title: "Copy Image", action: nil, keyEquivalent: "")
  let reload = NSMenuItem(title: "Reload", action: nil, keyEquivalent: "r")
  reload.identifier = .init("WKMenuItemIdentifierReload")
  let menu = NSMenu()
  for item in [copy, image, reload] { menu.addItem(item) }
  let event = try fileMenuEvent()
  web.willOpenMenu(menu, with: event)
  web.willOpenMenu(menu, with: event)
  #expect(menu.items[0] === copy)
  #expect(menu.items[1] === image)
  #expect(menu.items[2].identifier?.rawValue == "aster.sendToChat")
  #expect(menu.items.filter { $0.identifier?.rawValue == "aster.sendToChat" }.count == 1)
  #expect(!menu.items.contains { $0.title == L("在访达中显示") })
  try "# after reload".write(to: url, atomically: true, encoding: .utf8)
  let action = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" })
  #expect(NSApp.sendAction(try #require(action.action), to: action.target, from: action))
  #expect(model.selectedTab?.activeRuntime?.documentText == "# after reload")
  var html = ""
  for _ in 0..<100 {
    html = (try? await web.evaluateJavaScript("document.body.innerText") as? String) ?? ""
    if html.contains("after reload") { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(html.contains("after reload"))
}

@MainActor
func fileMenuDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(fileMenuDescendants) }

@Test("公共文件菜单复制绝对路径，文件缺失后禁用外部打开")
@MainActor
func filePaneFileActionsCopyPathAndDisableMissingFile() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
  try "content".write(to: url, atomically: true, encoding: .utf8)
  let clipboard = NSPasteboard(name: .init("FilePathTests.\(UUID().uuidString)"))
  defer { clipboard.releaseGlobally(); try? FileManager.default.removeItem(at: url) }
  var errors: [String] = []
  let menu = FilePaneFileActions.menu(url: url, pasteboard: clipboard) { errors.append($0) }
  let copy = try #require(menu.items.first { $0.title == L("复制文件路径") })
  #expect(NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy))
  #expect(clipboard.string(forType: .string) == url.path)
  try FileManager.default.removeItem(at: url)
  let missing = FilePaneFileActions.menu(url: url, pasteboard: clipboard) { errors.append($0) }
  #expect(missing.items.first { $0.title == L("使用默认应用打开") }?.isEnabled == false)
  #expect(missing.items.first { $0.title == L("在访达中显示") }?.isEnabled == false)
  #expect(errors.isEmpty)
}

@Test("二进制预览右键提供文件动作并将所选 hex 行交给 Chat")
@MainActor
func filePaneBinaryContextSendsSelectedHexRows() throws {
  let (model, controller, _, url) = try filePaneTestFixture("\0binary", extension: "bin", mode: .automatic)
  defer { model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let table = try #require(fileMenuDescendants(controller.view).compactMap { $0 as? NSTableView }.first)
  table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  let menu = try #require(table.menu)
  menu.delegate?.menuWillOpen?(menu)
  #expect(menu.items.first { $0.title == L("复制") }?.isEnabled == true)
  #expect(menu.items.contains { $0.title == L("复制文件路径") })
  var sent: AgentChatPresentation?
  let subscription = model.agentChatPresentationRequested.sink { sent = $0 }
  defer { subscription.cancel() }
  let chat = try #require(menu.items.first { $0.title == L("发送到 Chat") + "…" })
  #expect(NSApp.sendAction(try #require(chat.action), to: chat.target, from: chat))
  #expect(sent?.fileContext?.path == url.path)
  #expect(sent?.selection?.contains("00 62 69 6E 61 72 79") == true)
}
