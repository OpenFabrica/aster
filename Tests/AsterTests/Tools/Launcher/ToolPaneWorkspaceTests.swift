// 工具 Pane 在工作区里的行为：开成 Pane、会话按 Pane 缓存与释放、不进快照与关闭历史、预填找最近终端。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 一个带初始终端标签的隔离工作区。
@MainActor
private struct ToolPaneWorkspace {
  let model: AppModel
  let defaults: UserDefaults
  let suite: String

  /// 建隔离的偏好域与模型，并开好初始终端标签。
  init() throws {
    // 工具中心组装环境时读 NSApp 的外观。
    _ = NSApplication.shared
    suite = "ToolPaneWorkspace.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    model = AppModel(defaults: defaults)
    model.ensureInitialTab()
  }

  /// 清掉测试写入的偏好域。
  func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

/// 内置 JSON 工具条目。直接取内置清单，不依赖工具中心何时完成扫描。
private func jsonEntry() throws -> ToolCatalogEntry {
  let feature = try #require(
    BuiltinToolCatalog.manifest().features.first { $0.code == ToolBuiltinHandler.json.rawValue })
  return ToolCatalogEntry(
    pluginID: BuiltinToolCatalog.pluginID, pluginName: "Aster", pluginVersion: "1.0.0", source: .builtin,
    feature: feature)
}

/// 轮询等待条件成立；会话缓存在下一轮主队列核对，工具的关闭请求也延后一轮执行。
@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@MainActor
@Test("工具开成当前标签里的 Pane：记录功能 id，会话带着输入与来源缓存，重复取是同一个控制器")
func openToolPaneSplitsActiveTabAndCachesSession() throws {
  let workspace = try ToolPaneWorkspace()
  defer { workspace.cleanUp() }
  let model = workspace.model
  let tab = try #require(model.selectedTab)
  let terminalID = tab.activePaneID
  let origin = try #require(model.toolTerminalOrigin())
  let entry = try jsonEntry()
  let input = ToolInput(text: "{\"a\":1}", source: .typed)

  #expect(model.openToolPane(entry: entry, input: input, origin: origin))

  let toolPane = try #require(tab.layout.allPanes.first { $0.kind == .tool })
  #expect(toolPane.resourcePath == entry.id)
  #expect(tab.layout.allPanes.map(\.id) == [terminalID, toolPane.id])
  #expect(tab.activePaneID == toolPane.id)
  #expect(tab.runtime(for: toolPane.id)?.terminalSession == nil)
  // 焦点在工具 Pane 上时没有可预填的来源终端。
  #expect(model.toolTerminalOrigin() == nil)
  let session = try #require(model.toolPaneSession(for: toolPane))
  #expect(session.request.input == input)
  #expect(session.request.origin === origin)
  #expect(model.toolPaneSession(for: toolPane) === session)
  #expect(model.toolPaneSessions.cachedPaneIDs == [toolPane.id])
  #expect(model.nearestTerminalOrigin(toPane: toolPane.id)?.paneID == terminalID)
}

@MainActor
@Test("保存的工作区快照里没有工具 Pane，分屏由终端顶替")
func persistedWorkspaceOmitsToolPanes() throws {
  let workspace = try ToolPaneWorkspace()
  defer { workspace.cleanUp() }
  let model = workspace.model
  let terminalID = try #require(model.selectedTab).activePaneID

  #expect(model.openToolPane(entry: try jsonEntry(), input: ToolInput(), origin: nil))

  let data = try #require(workspace.defaults.data(forKey: "aster.workspace.snapshot.v1"))
  let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
  #expect(snapshot.tabs.flatMap(\.layout.allPanes).map(\.id) == [terminalID])
}

@MainActor
@Test("关闭工具 Pane 后释放会话，也不进「重新打开」历史")
func closingToolPaneReleasesSessionWithoutHistory() async throws {
  let workspace = try ToolPaneWorkspace()
  defer { workspace.cleanUp() }
  let model = workspace.model
  let tab = try #require(model.selectedTab)
  let terminalID = tab.activePaneID
  #expect(model.openToolPane(entry: try jsonEntry(), input: ToolInput(), origin: nil))
  let toolID = tab.activePaneID
  #expect(model.toolPaneSessions.cachedPaneIDs == [toolID])

  model.closeActivePane()

  #expect(tab.layout.allPanes.map(\.id) == [terminalID])
  #expect(try await waitUntil { model.toolPaneSessions.cachedPaneIDs.isEmpty })
  #expect(!model.reopenLastClosedTab())
}

@MainActor
@Test("工具请求关闭自己时关掉它所在的 Pane")
func toolCloseRequestClosesItsPane() async throws {
  let workspace = try ToolPaneWorkspace()
  defer { workspace.cleanUp() }
  let model = workspace.model
  let tab = try #require(model.selectedTab)
  #expect(model.openToolPane(entry: try jsonEntry(), input: ToolInput(), origin: nil))
  let toolPane = try #require(tab.layout.allPanes.first { $0.kind == .tool })
  let session = try #require(model.toolPaneSession(for: toolPane))
  let host = try #require(session.host)

  host.toolSessionDidRequestClose(session)

  #expect(try await waitUntil { !tab.layout.allPanes.contains { $0.id == toolPane.id } })
  #expect(try await waitUntil { model.toolPaneSessions.cachedPaneIDs.isEmpty })
}

@MainActor
@Test("只剩工具 Pane 的标签：预填找不到终端时提示；关闭后不进「重新打开」历史")
func toolOnlyTabHasNoPrefillTargetAndSkipsHistory() async throws {
  let workspace = try ToolPaneWorkspace()
  defer { workspace.cleanUp() }
  let model = workspace.model
  let tab = try #require(model.selectedTab)
  let terminalID = tab.activePaneID
  #expect(model.openToolPane(entry: try jsonEntry(), input: ToolInput(), origin: nil))
  let toolPane = try #require(tab.layout.allPanes.first { $0.kind == .tool })
  // 直接从标签摘掉终端（不经 AppModel，不进关闭历史），得到只剩工具 Pane 的标签。
  #expect(tab.closePane(id: terminalID))
  let session = try #require(model.toolPaneSession(for: toolPane))
  let host = try #require(session.host)

  #expect(!host.toolSession(session, insertIntoTerminal: "echo hi"))
  #expect(model.notice == L("这个标签里没有可以预填的终端 Pane"))

  model.closeTab(id: tab.id)

  #expect(!model.tabs.contains { $0 === tab })
  #expect(try await waitUntil { model.toolPaneSessions.cachedPaneIDs.isEmpty })
  #expect(!model.reopenLastClosedTab())
}

@MainActor
@Test("缓存里没有的工具 Pane（例如拖来的）按功能 id 现建会话；功能不存在时返回 nil")
func toolPaneSessionIsCreatedOnDemandFromEntryID() throws {
  let workspace = try ToolPaneWorkspace()
  defer { workspace.cleanUp() }
  let model = workspace.model
  let entryID = try jsonEntry().id
  try #require(ToolCenter.shared.entry(id: entryID) != nil)
  let descriptor = PaneDescriptor(kind: .tool, workingDirectory: NSHomeDirectory(), resourcePath: entryID)

  let session = try #require(model.toolPaneSession(for: descriptor))

  #expect(session.request.entry.id == entryID)
  #expect(session.request.origin == nil)
  #expect(session.request.input.text == nil)
  #expect(model.toolPaneSession(for: descriptor) === session)
  let missing = PaneDescriptor(
    kind: .tool, workingDirectory: NSHomeDirectory(), resourcePath: "com.example.missing/feature")
  #expect(model.toolPaneSession(for: missing) == nil)
}
