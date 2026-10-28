// 工具面板这个浮动窗口的行为：「窗口 → 工具面板」能呼出；面板拿着键盘时 ⌘W 只收起面板、分屏类菜单置灰；
// sheet 挂在面板上时不自动收起、关掉后键盘回到面板、收起面板时剩下的 sheet 按取消结束；
// 拖到搜索框上的文件按文件输入处理，而不是把路径插成文字；钉住后点去别处不收起，只有搜索行空白与底栏能拖动面板。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 轮询等待条件成立；面板的显示、淡出与 sheet 的进出都要让出几轮主队列。
@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// 视图树里所有子孙视图。
@MainActor
private func descendants(of view: NSView) -> [NSView] {
  view.subviews + view.subviews.flatMap { descendants(of: $0) }
}

/// 一个用来挂在面板上的空白 sheet。
@MainActor
private func makeSheet() -> NSWindow {
  let sheet = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered,
    defer: false)
  sheet.isReleasedWhenClosed = false
  return sheet
}

/// 这几个用例都要让面板成为 key window，并行跑会互相抢走 key、触发自动收起，所以串行。
@MainActor
@Suite(.serialized)
struct ToolLauncherPanelWindowTests {
  @Test("工具面板拿着键盘时 ⌘W 只收起面板，⌥⌘W 等分屏命令置灰，工作区标签与 Pane 不受影响")
  func toolLauncherMenuCloseDoesNotTouchWorkspace() async throws {
    let suite = "ToolLauncherMenuTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    preferences.configuration.general.closeWindowConfirmation = .never
    let model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    model.splitSelectedTab(.right)
    let tabID = model.selectedTab?.id
    let paneIDs = model.selectedTab?.layout.allPanes.map(\.id)
    let delegate = AsterAppDelegate(model: model, preferences: preferences)
    let oldWindowsMenu = NSApp.windowsMenu
    defer {
      _ = delegate.applicationShouldTerminate(NSApp)
      NSApp.windowsMenu = oldWindowsMenu
    }
    let items = delegate.makeMainMenu().items.flatMap { $0.submenu?.items ?? [] }
    let open = try #require(items.first { $0.title == L("工具面板") })
    #expect(open.keyEquivalent.isEmpty)

    #expect(NSApp.sendAction(try #require(open.action), to: open.target, from: open))
    let panel = try #require(NSApp.keyWindow)
    #expect(panel.title == "Aster Tools")

    let closePane = try #require(items.first { $0.action == NSSelectorFromString("closePane:") })
    #expect(!delegate.validateMenuItem(closePane))
    let close = try #require(
      items.first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == [.command] })
    #expect(NSApp.sendAction(try #require(close.action), to: close.target, from: close))

    #expect(try await waitUntil { !panel.isVisible })
    #expect(model.selectedTab?.id == tabID)
    #expect(model.selectedTab?.layout.allPanes.map(\.id) == paneIDs)
  }

  @Test("sheet 挂在面板上时面板不收起，关掉后键盘回到面板；收起面板时剩下的 sheet 按取消结束")
  func toolLauncherKeepsPanelWhileSheetIsAttached() async throws {
    let suite = "ToolLauncherPanelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    let controller = ToolLauncherController(preferences: AppPreferences(defaults: defaults)) { _ in model }
    defer { controller.shutdown() }

    controller.show(request: nil)
    let panel = try #require(NSApp.keyWindow)
    #expect(panel.title == "Aster Tools")

    let confirm = makeSheet()
    panel.beginSheet(confirm, completionHandler: nil)
    #expect(try await waitUntil { panel.attachedSheet === confirm })
    // 失去 key 的判断在下一轮主队列；多等几轮，确认没有被收起。
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.isPresented)
    #expect(panel.isVisible)

    panel.endSheet(confirm)
    #expect(try await waitUntil { panel.isKeyWindow })
    #expect(controller.isPresented)

    let picker = makeSheet()
    var response: NSApplication.ModalResponse?
    panel.beginSheet(picker) { response = $0 }
    #expect(try await waitUntil { panel.attachedSheet === picker })
    controller.hide()
    #expect(try await waitUntil { response != nil })
    #expect(response == .cancel)
    #expect(!controller.isPresented)
  }

  @Test("点图钉钉住后点去别的窗口面板不收起，快捷键先叫回再收起；取消钉住后恢复失焦自动收起")
  func pinnedToolLauncherStaysWhenFocusMovesAway() async throws {
    let suite = "ToolLauncherPinTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    let controller = ToolLauncherController(preferences: AppPreferences(defaults: defaults)) { _ in model }
    defer { controller.shutdown() }
    // 测试宿主不是前台应用，普通窗口拿不到键盘；用非激活面板扮演「别的窗口」。
    let other = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled, .nonactivatingPanel],
      backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.orderOut(nil) }

    controller.show(request: nil)
    let panel = try #require(NSApp.keyWindow)
    let contentView = try #require(panel.contentView)
    let pin = try #require(
      descendants(of: contentView).compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "tool-launcher-pin" })
    pin.performClick(nil)
    #expect(controller.isPinned)
    #expect(pin.toolTip == L("取消钉住"))
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))

    other.makeKeyAndOrderFront(nil)
    #expect(try await waitUntil { other.isKeyWindow })
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.isPresented)
    #expect(panel.isVisible)

    // 钉住的面板在背后时，快捷键把它叫回前面；拿着键盘时再按才收起。
    controller.toggle()
    #expect(try await waitUntil { panel.isKeyWindow })
    #expect(controller.isPresented)
    controller.toggle()
    #expect(try await waitUntil { !panel.isVisible })
    #expect(controller.isPinned)

    controller.setPinned(false)
    #expect(panel.collectionBehavior.contains(.moveToActiveSpace))
    controller.show(request: nil)
    #expect(try await waitUntil { panel.isKeyWindow })
    other.makeKeyAndOrderFront(nil)
    #expect(try await waitUntil { !controller.isPresented })
  }
}

@MainActor
@Test("拖动把手：搜索行空白与底栏能拖动面板，搜索框、图钉与结果行照常接收点击")
func toolLauncherDragHandlesAreChromeOnly() throws {
  _ = NSApplication.shared
  let content = ToolLauncherViewController()
  content.reset(context: ToolContext())
  let views = descendants(of: content.view)
  let searchBar = try #require(views.first { $0 is ToolLauncherSearchBar })
  let footer = try #require(views.first { $0 is ToolLauncherFooterView })
  let searchField = try #require(views.first { $0.identifier?.rawValue == "tool-launcher-search" })
  let pin = try #require(views.first { $0.identifier?.rawValue == "tool-launcher-pin" })

  #expect(content.isDragHandle(searchBar))
  #expect(content.isDragHandle(footer))
  #expect(footer.subviews.allSatisfy { content.isDragHandle($0) })
  #expect(!content.isDragHandle(searchField))
  #expect(!content.isDragHandle(pin))
  #expect(!content.isDragHandle(content.view))
  for row in views where row is OpenQuicklyRowView { #expect(!content.isDragHandle(row)) }
}

@MainActor
@Test("搜索框用专用 field editor：拖到上面的文件按文件输入处理")
func toolLauncherSearchFieldTakesDroppedFilesAsFiles() throws {
  _ = NSApplication.shared
  let content = ToolLauncherViewController()
  content.reset(context: ToolContext())
  let searchField = try #require(
    descendants(of: content.view).compactMap { $0 as? NSTextField }
      .first { $0.identifier?.rawValue == "tool-launcher-search" })

  let editor = try #require(content.fieldEditor(for: searchField) as? ToolLauncherSearchFieldEditor)
  #expect(editor.isFieldEditor)
  #expect(content.fieldEditor(for: NSTextField()) == nil)
  #expect(content.fieldEditor(for: nil) == nil)

  editor.onDropFiles?(["/tmp/report.json"])
  #expect(content.files == ["/tmp/report.json"])
  #expect(searchField.stringValue.isEmpty)
}
