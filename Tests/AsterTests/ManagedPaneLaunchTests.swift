// 新建受管 Pane 的启动顺序与受管 Pane 的前台命令判定（真实 aster-session 服务、真实进程）。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 本仓库构建出的运行时二进制。缺失即判失败，不静默跳过。
private func runtimeBinaryPath() -> String {
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return repository.appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
}

/// 只对当前用户开放的私有状态父目录。
private func makeStateParent() throws -> URL {
  let base = URL(fileURLWithPath: "/tmp/aster-p2-tests", isDirectory: true)
  try? FileManager.default.createDirectory(
    at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return directory
}

/// 用显式端点装一个指向临时服务的协调器；返回恢复原协调器并停服务的清理闭包。
@MainActor
private func installTestCoordinator(name: String) throws -> (ManagedTerminalCoordinator, () -> Void)? {
  let binary = runtimeBinaryPath()
  #expect(FileManager.default.isExecutableFile(atPath: binary), "缺少运行时二进制：\(binary)")
  guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
  let stateParent = try makeStateParent()
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: stateParent.path,
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: name,
    ])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = coordinator
  return (coordinator, {
    ManagedTerminalCoordinator.shared = previous
    let stop = Process()
    stop.executableURL = URL(fileURLWithPath: binary)
    stop.arguments = ["server", "stop", stateParent.path, name]
    stop.standardOutput = FileHandle.nullDevice
    stop.standardError = FileHandle.nullDevice
    try? stop.run()
    stop.waitUntilExit()
  })
}

/// 隔离偏好与一个挂终端用的真实窗口。
@MainActor
private func makeHostWindow() -> (AppPreferences, NSWindow) {
  _ = NSApplication.shared
  let suite = "AsterTests.managedLaunch.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.makeKeyAndOrderFront(nil)
  return (AppPreferences(defaults: defaults), window)
}

@MainActor
private func mount(_ session: TerminalSession, preferences: AppPreferences, in window: NSWindow) {
  let host = session.makeTerminalHost(preferences: preferences)
  host.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
}

@Test("新建受管 Pane 等受管终端建好再挂显示桥，不先起一个本地 Shell")
@MainActor
func newManagedPaneNeverLaunchesLocalShellTwin() async throws {
  guard let (_, cleanup) = try installTestCoordinator(name: "managedlaunch") else { return }
  defer { cleanup() }
  let (preferences, window) = makeHostWindow()
  defer { window.orderOut(nil) }

  let session = TerminalSession(workingDirectory: "/tmp")
  let descriptor = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  var bound: ManagedTerminalReference?
  ManagedTerminalBinder.bind(
    session: session, descriptor: descriptor, isRestored: false, shell: "/bin/zsh"
  ) { bound = $0 }
  // 视图树紧接着就来要 host（与工作区刷新同一轮）：此时只能是占位，不能有进程。
  #expect(session.managedLaunchPending)
  mount(session, preferences: preferences, in: window)
  #expect(session.lifecycleState == .notStarted)
  #expect(!session.isRunning, "受管终端建好之前不得落地本地 Shell")

  for _ in 0..<300 where bound == nil || session.lifecycleState != .running {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(bound != nil)
  #expect(session.isManagedTerminal)
  #expect(!session.managedLaunchPending)
  // surface 的子进程必须是显示桥：布局记下的受管终端就是用户实际在用的那一个。
  let surfaceChild = try #require(session.processIdentifier)
  // 读取时桥可能还没 exec，argv 仍是 `/bin/sh -c "<aster-session> terminal attach …"`，按整条命令判断。
  let command = (ProcessArgumentsReader.arguments(of: surfaceChild) ?? []).joined(separator: " ")
  #expect(
    command.contains("aster-session") && command.contains("attach"),
    "surface 子进程不是显示桥：\(command)")
  session.stop(immediately: true)
}

@Test("本机受管 Pane 的前台命令按服务端 Shell 判定，而不是显示桥")
@MainActor
func localManagedPaneSeesForegroundCommandOfManagedShell() async throws {
  guard let (coordinator, cleanup) = try installTestCoordinator(name: "managedforeground") else { return }
  defer { cleanup() }
  let (preferences, window) = makeHostWindow()
  defer { window.orderOut(nil) }

  // 交互式 sh 开作业控制：sleep 是独立的前台进程组，与 Codex 在 zsh 里运行时相同。
  let created = try coordinator.createTerminal(
    workingDirectory: "/tmp", argv: ["/bin/sh", "-ic", "sleep 30; true"])
  let session = TerminalSession(workingDirectory: "/tmp")
  session.bindManagedTerminal(created.reference)
  mount(session, preferences: preferences, in: window)
  for _ in 0..<300 where !session.hasForegroundCommand {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.hasForegroundCommand)
  // 轮询不能再把它改回「没有命令」：以前它拿显示桥自己比较，每秒清零一次。
  try await Task.sleep(for: .milliseconds(1500))
  #expect(session.hasRunningCommand)
  session.stop(immediately: true)
}
