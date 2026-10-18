// 真实 Shell 与受管显示桥的目录同步、侧栏分组和滚动视口回归。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 恢复和全新 Pane 必须走同一条 PTY → OSC 7 → Session → 标签布局同步链路。
@Test("新建与恢复的 Ghostty Pane 切目录后同步标签目录", arguments: [false, true])
@MainActor
func ghosttyWorkingDirectoryFollowsShellAfterRestore(restored: Bool) async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.cwd.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let initial = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-cwd-\(UUID().uuidString)", isDirectory: true)
  let target = initial.appendingPathComponent("mailez", isDirectory: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: initial) }

  if restored {
    let tab = WorkspaceTabSnapshot(
      id: UUID(), title: "app",
      layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: initial.path)))
    let snapshot = WorkspaceSnapshot(
      selectedTabID: tab.id, tabs: [tab], savedAt: Date(timeIntervalSinceNow: -60))
    defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")
  }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.autocompleteOnDeviceLearning = false
  if restored { model.ensureInitialTab() } else { model.newTab(workingDirectory: initial.path) }
  defer { model.tabs.forEach { $0.stop(immediately: true) } }
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.layoutIfNeeded()

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  let view = try #require(descendants(controller.view).compactMap { $0 as? GhosttySurfaceView }.first)
  for _ in 0..<200 where !session.shellIntegrationDetected {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.shellIntegrationDetected, "restored=\(restored)：未收到真实 Shell 集成标记")
  #expect(view.typeText("cd '\(target.path)'; pwd\n"))
  for _ in 0..<200 where session.currentWorkingDirectory != target.path {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.readText(includeScrollback: true)?.contains(target.path) == true)
  #expect(session.currentWorkingDirectory == target.path, "restored=\(restored)：终端 cwd 未同步")
  #expect(tab.workingDirectory == target.path, "restored=\(restored)：标签 cwd 未同步")
}

/// 显示桥收到进度不能退回 RIS 快照：目录事件和用户正在查看的历史视口必须一起保留。
@Test("受管 Pane 的进度与目录同批更新时保留侧栏目录和滚动视口")
@MainActor
func ghosttyManagedProgressPreservesDirectoryAndScrollback() async throws {
  _ = NSApplication.shared
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let binary = ProcessInfo.processInfo.environment["ASTER_TEST_SESSION_BINARY"]
    ?? repository.appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
  _ = try #require(FileManager.default.isExecutableFile(atPath: binary), "缺少运行时：\(binary)")
  let root = URL(fileURLWithPath: "/tmp/aster-cwd-\(UUID().uuidString)", isDirectory: true)
  let initial = root.appendingPathComponent("app", isDirectory: true)
  let target = root.appendingPathComponent("mailez", isDirectory: true)
  let trigger = root.appendingPathComponent("progress")
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  try FileManager.default.createDirectory(at: initial, withIntermediateDirectories: false)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
  defer {
    do { try FileManager.default.removeItem(at: root) }
    catch { Issue.record("清理测试目录失败：\(error)") }
  }
  let coordinator = ManagedTerminalCoordinator(environment: [
    ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
    ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: root.path,
    ManagedTerminalCoordinator.sessionNameEnvironmentKey: "cwdtests",
  ])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = coordinator
  defer { ManagedTerminalCoordinator.shared = previous }
  _ = try #require(coordinator.connect())
  defer {
    let stop = Process()
    stop.executableURL = URL(fileURLWithPath: binary)
    stop.arguments = ["server", "stop", root.path, "cwdtests"]
    stop.standardOutput = FileHandle.nullDevice
    do { try stop.run(); stop.waitUntilExit() }
    catch { Issue.record("停止测试服务失败：\(error)") }
  }
  // 先产生历史，再由文件触发后台更新；不能键入命令，键盘输入本身就会把视口拉回底部。
  let script = "seq 1 200; printf 'READY\\n'; "
    + "while [ ! -f '\(trigger.path)' ]; do sleep 0.02; done; cd '\(target.path)'; "
    + "printf '\\033]7;file://localhost%s\\007\\033]9;4;1;50\\007PROGRESS_DONE\\n' \"$PWD\"; "
    + "while :; do sleep 1; done"
  let created = try coordinator.createTerminal(
    workingDirectory: initial.path, argv: ["/bin/sh", "-c", script])
  let suite = "AsterTests.managedcwd.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let snapshotTab = WorkspaceTabSnapshot(
    id: UUID(), title: "app", layout: .leaf(PaneDescriptor(
      kind: .terminal, workingDirectory: initial.path, managedTerminal: created.reference)))
  let snapshot = WorkspaceSnapshot(selectedTabID: snapshotTab.id, tabs: [snapshotTab])
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.sidebarTabGrouping = .project
  model.ensureInitialTab()
  defer { model.tabs.forEach { $0.stop(immediately: true) } }
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.layoutIfNeeded()
  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  let view = try #require(descendants(controller.view).compactMap { $0 as? GhosttySurfaceView }.first)
  for _ in 0..<200 where view.readText(includeScrollback: true)?.contains("READY") != true {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.readText(includeScrollback: true)?.contains("READY") == true)
  // 初次附加会收敛窗口几何并触发服务端快照，先等它落定，避免把启动 resize 算成进度回归。
  var stableGeometry: String?
  var stablePolls = 0
  for _ in 0..<100 where stablePolls < 10 {
    try await Task.sleep(for: .milliseconds(20))
    let info = try #require(view.bufferInfo())
    let geometry = "\(info.screen_rows):\(info.viewport_rows):\(view.bounds)"
    stablePolls = geometry == stableGeometry ? stablePolls + 1 : 0
    stableGeometry = geometry
  }
  #expect(stablePolls == 10)
  #expect(view.performBindingAction("scroll_page_up"))
  // binding 在引擎下一次 tick 执行，不能把入队成功当作视口已经移动。
  for _ in 0..<100 {
    let info = try #require(view.bufferInfo())
    if info.viewport_top + UInt64(info.viewport_rows) < info.screen_rows { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let scrolled = try #require(view.bufferInfo())
  #expect(scrolled.viewport_top + UInt64(scrolled.viewport_rows) < scrolled.screen_rows)
  try Data().write(to: trigger)
  for _ in 0..<200 where view.readText(includeScrollback: true)?.contains("PROGRESS_DONE") != true {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.readText(includeScrollback: true)?.contains("PROGRESS_DONE") == true)
  // 等待 CWD 的定向更新及侧栏分组重建落定。
  try await Task.sleep(for: .milliseconds(200))
  #expect(session.currentWorkingDirectory == target.path)
  #expect(tab.workingDirectory == target.path)
  let headers = descendants(controller.view).compactMap { $0 as? NSTextField }
    .filter { $0.identifier?.rawValue == "sidebar-group-header" }
  #expect(headers.contains { $0.stringValue == "mailez" })
  let after = try #require(view.bufferInfo())
  #expect(after.screen_rows >= scrolled.screen_rows, "进度不能清除回滚历史")
  #expect(after.viewport_top == scrolled.viewport_top, "进度不能把历史视口拉回底部")
}
