// Files 的目录跟随、完整枚举与异步切换回归。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
private func filesFixture(client: WorkspaceInspectionClient) -> (AppModel, DetailsPanelViewController) {
  let defaults = UserDefaults(suiteName: "DetailsFilesDirectoryTests.\(UUID().uuidString)")!
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  return (model, controller)
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap { descendants($0) }
}

@Test("Files 的折叠子目录不能耗尽顶层文件名额")
func filesListingKeepsAllRootEntriesWithoutScanningCollapsedChildren() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let nested = root.appendingPathComponent("aaa")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  for index in 0..<510 { try Data().write(to: nested.appendingPathComponent("child-\(index)")) }
  try Data().write(to: root.appendingPathComponent("zzz.txt"))
  let nodes = await WorkspaceInspectionService.inspectFiles(directory: root.path)
  #expect(nodes.map(\.name) == ["aaa", "zzz.txt"])
}

@Test("Files 表格完整展示超过两千个顶层条目")
@MainActor
func filesTableDoesNotSilentlyTruncateRootEntries() async throws {
  let client = WorkspaceInspectionClient(
    information: { _ in .init(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { directory, _ in
      (0..<2_050).map {
        WorkspaceFileNode(path: "\(directory)/file-\($0)", name: "file-\($0)", depth: 0, isDirectory: false)
      }
    })
  let (model, controller) = filesFixture(client: client)
  defer { model.selectedTab?.stop(immediately: true) }
  for _ in 0..<5 { await Task.yield() }
  let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(table.numberOfRows == 2_050)
}

@Test("Files 切换隐藏项时必须跟随正在读取的新终端目录")
@MainActor
func filesHiddenToggleDoesNotRestorePreviousDirectory() async throws {
  var requested: [String] = []
  let client = WorkspaceInspectionClient(
    information: { _ in .init(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { directory, _ in requested.append(directory); return [] })
  let (model, controller) = filesFixture(client: client)
  defer { model.selectedTab?.stop(immediately: true) }
  for _ in 0..<5 { await Task.yield() }
  let tab = try #require(model.selectedTab)
  tab.workingDirectoryChanged.send((paneID: tab.activePaneID, directory: "/tmp/new-files-cwd"))
  let toggle = try #require(descendants(controller.view).compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "details-files-show-hidden" })
  toggle.performClick(nil)
  for _ in 0..<5 { await Task.yield() }
  #expect(requested.last == "/tmp/new-files-cwd")
}

@Test("Files 重新展开面板会重读同一个终端目录")
@MainActor
func filesReopeningRefreshesSameDirectory() async throws {
  var count = 0
  let client = WorkspaceInspectionClient(
    information: { _ in .init(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { _, _ in count += 1; return [] })
  let (model, controller) = filesFixture(client: client)
  defer { model.selectedTab?.stop(immediately: true) }
  for _ in 0..<5 { await Task.yield() }
  let initial = count
  controller.setPresentationActive(false)
  controller.setPresentationActive(true)
  for _ in 0..<5 { await Task.yield() }
  #expect(count == initial + 1)
}

@Test("Files 按需读取隐藏目录和超过三层的路径，不遍历折叠兄弟或符号链接")
@MainActor
func filesExpandedSnapshotLoadsDeepAndHiddenDirectoriesOnlyOnDemand() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let deep = root.appendingPathComponent(".hidden/a/b/c/d")
  try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
  try Data().write(to: deep.appendingPathComponent("deep.txt"))
  try FileManager.default.createDirectory(at: root.appendingPathComponent("collapsed"), withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("collapsed/unread.txt"))
  try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)
  defer { try? FileManager.default.removeItem(at: root) }
  let expanded = Set([".hidden", ".hidden/a", ".hidden/a/b", ".hidden/a/b/c", ".hidden/a/b/c/d", "link"]
    .map { root.appendingPathComponent($0).path })
  let nodes = await DetailsFileTreeSnapshot.load(
    directory: root.path, expandedPaths: expanded, includeHidden: true,
    read: { await WorkspaceInspectionService.inspectFiles(directory: $0, includeHidden: $1) })
  #expect(nodes.contains { $0.name == "deep.txt" && $0.depth == 5 })
  #expect(!nodes.contains { $0.name == "unread.txt" })
  #expect(nodes.filter { $0.name == "link" }.count == 1)
}

@Test("Files 支持终端通过符号链接进入的逻辑目录")
func filesListingAcceptsSymlinkRoot() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("marker.txt"))
  let link = root.appendingPathExtension("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
  defer {
    try? FileManager.default.removeItem(at: link)
    try? FileManager.default.removeItem(at: root)
  }
  #expect(await WorkspaceInspectionService.inspectFiles(directory: link.path).map(\.name) == ["marker.txt"])
}

@Test("Files 展开目录与文件系统新建会更新同一张表格")
@MainActor
func filesLiveExpansionAndDirectoryWatcherRefreshRows() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let child = root.appendingPathComponent("folder")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  try Data().write(to: child.appendingPathComponent("inside.txt"))
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, controller) = filesFixture(client: .live)
  defer {
    controller.setPresentationActive(false)
    model.selectedTab?.stop(immediately: true)
  }
  let tab = try #require(model.selectedTab)
  tab.workingDirectoryChanged.send((paneID: tab.activePaneID, directory: root.path))
  let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" })
  func waitForRows(_ count: Int) async throws {
    for _ in 0..<100 {
      if table.numberOfRows == count { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(table.numberOfRows == count)
  }
  try await waitForRows(1)
  let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
  let disclosure = try #require(descendants(cell).compactMap { $0 as? NSButton }.first)
  disclosure.performClick(nil)
  try await waitForRows(2)
  try Data().write(to: child.appendingPathComponent("new-child.txt"))
  try await waitForRows(3)
  try Data().write(to: root.appendingPathComponent("new-root.txt"))
  try await waitForRows(4)
  disclosure.performClick(nil)
  try await waitForRows(2)
  try Data().write(to: child.appendingPathComponent("created-while-collapsed.txt"))
  disclosure.performClick(nil)
  try await waitForRows(5)
}

@Test("Files 快速切换目录后迟到的旧请求不得覆盖新目录")
@MainActor
func filesLateDirectoryResponseCannotReplaceCurrentRows() async throws {
  var pending: CheckedContinuation<[WorkspaceFileNode], Never>?
  let client = WorkspaceInspectionClient(
    information: { _ in .init(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { directory, _ in
      if directory == "/slow" { return await withCheckedContinuation { pending = $0 } }
      return [.init(path: directory + "/current.txt", name: "current.txt", depth: 0, isDirectory: false)]
    })
  let (model, controller) = filesFixture(client: client)
  defer { controller.setPresentationActive(false); model.selectedTab?.stop(immediately: true) }
  let tab = try #require(model.selectedTab)
  tab.workingDirectoryChanged.send((paneID: tab.activePaneID, directory: "/slow"))
  for _ in 0..<5 { await Task.yield() }
  let response = try #require(pending)
  tab.workingDirectoryChanged.send((paneID: tab.activePaneID, directory: "/current"))
  for _ in 0..<5 { await Task.yield() }
  response.resume(returning: [.init(path: "/slow/old.txt", name: "old.txt", depth: 0, isDirectory: false)])
  for _ in 0..<5 { await Task.yield() }
  let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" })
  let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
  let label = try #require(descendants(cell).compactMap { $0 as? PointingHandButton }.first)
  #expect(label.toolTip == "/current/current.txt")
}
