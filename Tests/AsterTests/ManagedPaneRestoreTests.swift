// 恢复受管 Pane 必须等后台服务交接与对账完成后才启动显示桥。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

@Test("恢复受管 Pane 等服务交接完成才附加，保留 Shell PID 并恢复输入")
@MainActor
func restoredManagedPaneWaitsForServiceHandoffBeforeLaunchingBridge() async throws {
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let binary = repository.appendingPathComponent(".build/debug/aster-session").path
  #expect(FileManager.default.isExecutableFile(atPath: binary))
  let root = URL(fileURLWithPath: "/tmp/aster-restore-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let endpoint = ManagedSessionEndpoint(
    binaryPath: binary, stateParentPath: root.path, sessionName: "restore")
  let client = LocalManagedSessionClient()
  _ = try client.ensureServer(endpoint)
  defer { try? client.stopServer(endpoint) }
  let before = try client.serverStatus(endpoint)
  let terminal = try client.createTerminal(
    endpoint, workingDirectory: "/tmp",
    argv: ["/bin/sh", "-c", "echo BEFORE_RESTORE; while read value; do echo GOT-$value; done"])

  // 冒充 App 更新后的运行时，并在交接入口设门闩，确定性覆盖视图先挂载、升级后完成的顺序。
  let wrapper = root.appendingPathComponent("aster-session-new")
  let started = root.appendingPathComponent("upgrade-started")
  let allowed = root.appendingPathComponent("allow-upgrade")
  let script = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo 'aster-session 0.1.0-dev protocol=1.0 build=restore-newer'; exit 0
    fi
    if [ "$1" = "server" ] && [ "$2" = "upgrade" ]; then
      touch '\(started.path)'
      while [ ! -f '\(allowed.path)' ]; do sleep 0.02; done
      exec '\(binary)' "$@" --force
    fi
    exec '\(binary)' "$@"
    """
  try script.write(to: wrapper, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
  let coordinator = ManagedTerminalCoordinator(environment: [
    ManagedTerminalCoordinator.binaryEnvironmentKey: wrapper.path,
    ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: root.path,
    ManagedTerminalCoordinator.sessionNameEnvironmentKey: "restore",
  ])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = coordinator
  defer { ManagedTerminalCoordinator.shared = previous }
  // 包装脚本的伪构建号用于强制交接；交接后仍不同不影响本用例的启动时序验收。
  let previousPrompt = ManagedTerminalCoordinator.confirmOutdatedServerRestart
  ManagedTerminalCoordinator.confirmOutdatedServerRestart = { _ in false }
  defer { ManagedTerminalCoordinator.confirmOutdatedServerRestart = previousPrompt }

  _ = NSApplication.shared
  let suite = "AsterTests.managedRestore.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  // 离屏窗口仍创建真实 Ghostty surface，不激活用户正在使用的 Aster 窗口。
  defer { window.orderOut(nil) }
  let session = TerminalSession(workingDirectory: "/tmp")
  defer { session.stop(immediately: true) }
  let descriptor = PaneDescriptor(
    kind: .terminal, workingDirectory: "/tmp", managedTerminal: terminal.reference)
  ManagedTerminalBinder.bind(
    session: session, descriptor: descriptor, isRestored: true, shell: "/bin/sh"
  ) { _ in Issue.record("恢复已有引用不得创建替代终端") }
  #expect(session.managedTerminal == terminal.reference)
  #expect(session.managedLaunchPending)
  let host = session.makeTerminalHost(preferences: preferences)
  host.frame = try #require(window.contentView).bounds
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()

  for _ in 0..<300 where !FileManager.default.fileExists(atPath: started.path) {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(FileManager.default.fileExists(atPath: started.path))
  #expect(session.lifecycleState == .notStarted, "交接前不得启动连到旧服务的显示桥")
  #expect(session.processIdentifier == nil)
  let status = try #require(host.subviews.first { $0 is ManagedTerminalLoadingView })
  #expect(status.accessibilityLabel() == "正在恢复终端…")
  _ = session.makeTerminalHost(preferences: preferences)
  #expect(host.subviews.filter { $0 is ManagedTerminalLoadingView }.count == 1)
  window.layoutIfNeeded()
  let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
  host.cacheDisplay(in: host.bounds, to: bitmap)
  let evidence = repository.appendingPathComponent(".build/remote-work-evidence", isDirectory: true)
  try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
  try #require(bitmap.representation(using: .png, properties: [:]))
    .write(to: evidence.appendingPathComponent("managed-restore-loading.png"))
  try Data().write(to: allowed)

  for _ in 0..<1000 where coordinator.connectionState != .online || session.managedLaunchPending {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(coordinator.connectionState == .online)
  #expect(!session.managedLaunchPending)
  #expect(!host.subviews.contains { $0 is ManagedTerminalLoadingView })
  for _ in 0..<300 where !(session.readActiveScreenText()?.contains("BEFORE_RESTORE") ?? false) {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.lifecycleState == .running)
  #expect(session.readActiveScreenText()?.contains("BEFORE_RESTORE") == true)
  let after = try client.serverStatus(endpoint)
  #expect(after.serverEpoch != before.serverEpoch)
  let live = try #require(client.listTerminals(endpoint).first)
  #expect(live.reference == terminal.reference)
  #expect(live.pid == terminal.pid)
  #expect(live.state == .running)
  #expect(session.sendAutomationBytes(Array("after-restore\r".utf8)))
  for _ in 0..<300 where !(session.readActiveScreenText()?.contains("GOT-after-restore") ?? false) {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.readActiveScreenText()?.contains("GOT-after-restore") == true)
  #expect(session.lifecycleState == .running, "服务交接后不得停在已分离")
}

@Test("恢复引用失效时结束等待并显示错误，不启动本机 Shell", arguments: [false, true])
@MainActor
func restoredMissingManagedPaneCompletesPendingLaunch(closedWhilePending: Bool) async throws {
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let binary = repository.appendingPathComponent(".build/debug/aster-session").path
  let root = URL(fileURLWithPath: "/tmp/aster-restore-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let endpoint = ManagedSessionEndpoint(
    binaryPath: binary, stateParentPath: root.path, sessionName: "missing")
  let client = LocalManagedSessionClient()
  _ = try client.ensureServer(endpoint)
  defer { try? client.stopServer(endpoint) }
  let identity = try client.serverStatus(endpoint)
  let missing = ManagedTerminalReference(
    server: identity.reference, terminalID: UUID().uuidString.lowercased())
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = ManagedTerminalCoordinator(environment: [
    ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
    ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: root.path,
    ManagedTerminalCoordinator.sessionNameEnvironmentKey: "missing",
  ])
  defer { ManagedTerminalCoordinator.shared = previous }
  let suite = "AsterTests.managedRestore.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  defer { withExtendedLifetime(preferences) {} }
  let session = TerminalSession(workingDirectory: "/tmp")
  defer { session.stop(immediately: true) }
  ManagedTerminalBinder.bind(
    session: session,
    descriptor: PaneDescriptor(kind: .terminal, workingDirectory: "/tmp", managedTerminal: missing),
    isRestored: true, shell: "/bin/sh"
  ) { _ in Issue.record("引用失效时不得自动创建替代终端") }
  _ = session.makeTerminalHost(preferences: preferences)
  #expect(session.managedLaunchPending)
  if closedWhilePending { session.stop(immediately: true) }
  for _ in 0..<300 where session.managedLaunchPending {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(!session.managedLaunchPending)
  #expect(session.managedFailure != nil)
  #expect(session.processIdentifier == nil)
  #expect(!session.isRunning)
  if closedWhilePending {
    #expect(session.lifecycleState == .stopping)
  } else {
    #expect(session.startupError?.contains("受管终端不可用") == true)
  }
  #expect(try client.listTerminals(endpoint).isEmpty)
}
