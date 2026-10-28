// 独立工具窗口：打开、标题与关闭后的清理。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite("ToolWindowController")
struct ToolWindowControllerTests {
  /// 在新窗口打开内置工具：窗口标题是功能标题；关窗口后结束会话并从登记表移除。
  @Test func opensBuiltinToolAndTearsDownOnClose() async throws {
    let entryID = ToolCatalogEntry.makeID(pluginID: BuiltinToolCatalog.pluginID, code: ToolBuiltinHandler.uuid.rawValue)
    let entry = try #require(ToolCenter.shared.entry(id: entryID))
    let before = ToolWindowController.openWindowCount
    let controller = ToolWindowController.open(
      request: ToolLaunchRequest(entry: entry, input: ToolInput(), origin: nil), model: nil)
    #expect(ToolWindowController.openWindowCount == before + 1)
    let window = try #require(controller.window)
    #expect(window.title == entry.feature.title)
    #expect(window is ToolStandaloneWindow)
    window.close()
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    #expect(ToolWindowController.openWindowCount == before)
  }
}
