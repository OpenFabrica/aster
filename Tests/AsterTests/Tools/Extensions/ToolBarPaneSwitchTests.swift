// 端到端复现：两个不同目录的终端 Pane，切换活动 Pane 后 tab.bottom 条要换成新 Pane 的结果。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：切换活动 Pane")
struct ToolBarPaneSwitchTests {
  @Test("切换活动 Pane 后 tab.bottom 条显示新 Pane 目录的结果")
  func tabBottomShowsNewPaneResultAfterSwitch() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-pane-switch-\(UUID().uuidString)", isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    for (dir, branch) in [(first, "alpha"), (second, "beta")] {
      let git = Process()
      git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      git.arguments = ["-C", dir.path, "init", "-q", "-b", branch]
      try git.run()
      git.waitUntilExit()
    }
    let a = PaneDescriptor(kind: .terminal, workingDirectory: first.path)
    let b = PaneDescriptor(kind: .terminal, workingDirectory: second.path)
    let suite = "ToolBarPaneSwitchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let snapshotTab = WorkspaceTabSnapshot(
      id: UUID(), title: "Panes", layout: .split(axis: .horizontal, first: .leaf(a), second: .leaf(b), ratio: 0.5))
    defaults.set(
      try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshotTab.id, tabs: [snapshotTab])),
      forKey: "aster.workspace.snapshot.v1")
    let model = AppModel(defaults: defaults)
    let preferences = AppPreferences(defaults: defaults)
    model.ensureInitialTab()
    let tab = try #require(model.selectedTab)
    tab.setActivePane(a.id)

    let catalog = FakeToolViewCatalog()
    let entry = makeToolViewEntry(slot: .tabBottom, triggers: [.cwd, .branch, .activePane])
    catalog.viewEntries = [entry]
    var runs: [String] = []
    let host = WorkspaceExtensionHost(
      model: model, preferences: preferences, catalog: catalog,
      runner: { request in
        let folder = (request.context.workingDirectory as NSString?)?.lastPathComponent ?? "-"
        runs.append("\(folder)@\(request.context.branch ?? "nil")")
        return ToolBarOutput(items: [ToolBarItem(text: folder)])
      })
    defer { host.teardown() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    host.windowProvider = { window }
    let bar = try #require(host.bar(for: .tabBottom))
    window.contentView?.addSubview(bar)
    host.workspaceDidRefresh()
    host.scheduler.isVisible = true

    func shownText() -> String? {
      guard let segment = (bar as? ToolBarView)?.segments.first, case .items(let items) = segment.content else {
        return nil
      }
      return items.first?.text
    }
    await pollUntil { shownText() == "first" }
    #expect(shownText() == "first")

    tab.setActivePane(b.id)
    await pollUntil { shownText() == "second" }
    #expect(shownText() == "second", "runs: \(runs)")

    tab.setActivePane(a.id)
    await pollUntil { shownText() == "first" }
    #expect(shownText() == "first", "runs: \(runs)")
  }
}
