import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 旧后台服务仍有终端在运行：先实时交接，终端不中断、不弹窗；交接不了才问用户——
// 并发连接只问一次，同意才替换，拒绝就保持原服务和终端。

/// 本仓库构建出的运行时（不带构建号）。
private func runtimeBinaryPath() -> String {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
}

/// 私有状态目录与冒充新版自带二进制的包装脚本（`--version` 报另一个构建号）。
/// 包装脚本让 `server upgrade` 失败，模拟交接不了、只能问用户的情形。
@MainActor
private func makeFixture(session: String) throws -> [String: String] {
  let base = URL(fileURLWithPath: "/tmp/aster-build-tests", isDirectory: true)
  try FileManager.default.createDirectory(
    at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let wrapper = directory.appendingPathComponent("aster-session-new").path
  let script = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "aster-session 0.1.0-dev protocol=1.0 build=newer"; exit 0; fi
    if [ "$1" = "server" ] && [ "$2" = "upgrade" ]; then
      echo '{"type":"client_error","code":"HandoffNotCompleted"}'; exit 1
    fi
    exec "\(runtimeBinaryPath())" "$@"
    """
  try script.write(toFile: wrapper, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper)
  return [
    ManagedTerminalCoordinator.binaryEnvironmentKey: wrapper,
    ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: directory.path,
    ManagedTerminalCoordinator.sessionNameEnvironmentKey: session,
  ]
}

/// 用旧服务起一个运行中的终端，再换一个新协调器模拟升级后的 App 去连接它。
@MainActor
private func outdatedServerWithTerminal(session: String) throws -> (
  coordinator: ManagedTerminalCoordinator, epoch: String, terminal: ManagedTerminalReference
) {
  let environment = try makeFixture(session: session)
  let previous = ManagedTerminalCoordinator(environment: environment)
  let identity = try #require(previous.connect())
  let terminal = try previous.createTerminal(
    workingDirectory: "/tmp", argv: ["/bin/sh", "-c", "sleep 30"])
  return (ManagedTerminalCoordinator(environment: environment), identity.serverEpoch, terminal.reference)
}

/// 测试结束停掉服务，连带结束其中的 `sleep`。
@MainActor
private func stopService(_ coordinator: ManagedTerminalCoordinator) {
  guard let endpoint = coordinator.endpoint else { return }
  try? LocalManagedSessionClient().stopServer(endpoint)
}

/// 带构建号 `newer` 的真实运行时，冒充新版 App 自带的二进制（与 `zig-out` 同源，增量编译几秒）。
private func newerRuntimeBinaryPath() throws -> String {
  let runtime = URL(fileURLWithPath: runtimeBinaryPath()).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let prefix = runtime.appendingPathComponent(".build/test-runtime-newer")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [
    "zig", "build", "-Dvt-prefix=.build/vt-host", "-Dbuild-id=newer", "--prefix", prefix.path,
  ]
  process.currentDirectoryURL = runtime
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0, "无法编译带构建号的测试运行时")
  return prefix.appendingPathComponent("bin/aster-session").path
}

/// 用例都替换同一个静态提示回调，必须串行，否则会互相覆盖。
@Suite(.serialized) @MainActor
struct ManagedServerRestartPromptTests {
  @Test func outdatedServerPromptIsAskedOnceAndRestartReplacesTheService() async throws {
    #expect(FileManager.default.isExecutableFile(atPath: runtimeBinaryPath()))
    let fixture = try outdatedServerWithTerminal(session: "prompt-yes")
    defer { stopService(fixture.coordinator) }
    var asked: [Int] = []
    let original = ManagedTerminalCoordinator.confirmOutdatedServerRestart
    ManagedTerminalCoordinator.confirmOutdatedServerRestart = { asked.append($0); return true }
    defer { ManagedTerminalCoordinator.confirmOutdatedServerRestart = original }

    // 启动时多个 Pane 同时对账：只能弹一次，所有调用拿到同一个新服务。
    async let first = fixture.coordinator.connectAsync()
    async let second = fixture.coordinator.connectAsync()
    let identities = await [first, second]
    #expect(asked == [1])
    #expect(identities.allSatisfy { $0?.serverEpoch != nil && $0?.serverEpoch != fixture.epoch })
  }

  @Test func outdatedServerWithRunningTerminalIsHandedOverWithoutAsking() async throws {
    #expect(FileManager.default.isExecutableFile(atPath: runtimeBinaryPath()))
    let newer = try newerRuntimeBinaryPath()
    var environment = try makeFixture(session: "handoff-live")
    environment[ManagedTerminalCoordinator.binaryEnvironmentKey] = newer
    let stateParent = try #require(environment[ManagedTerminalCoordinator.stateDirectoryEnvironmentKey])
    // 旧服务：不带构建号的 `zig-out` 这份，里面跑着一个终端。
    let start = Process()
    start.executableURL = URL(fileURLWithPath: runtimeBinaryPath())
    start.arguments = ["server", "start", stateParent, "handoff-live"]
    start.standardOutput = FileHandle.nullDevice
    try start.run()
    start.waitUntilExit()
    let coordinator = ManagedTerminalCoordinator(environment: environment)
    defer { stopService(coordinator) }
    let endpoint = try #require(coordinator.endpoint)
    let client = LocalManagedSessionClient()
    let before = try client.serverStatus(endpoint)
    let terminal = try client.createTerminal(
      endpoint, workingDirectory: "/tmp", argv: ["/bin/sh", "-c", "sleep 30"])
    var asked = 0
    let original = ManagedTerminalCoordinator.confirmOutdatedServerRestart
    ManagedTerminalCoordinator.confirmOutdatedServerRestart = { _ in asked += 1; return true }
    defer { ManagedTerminalCoordinator.confirmOutdatedServerRestart = original }

    let identity = await coordinator.connectAsync()
    #expect(asked == 0, "能实时交接时不应询问")
    #expect(identity?.build == "newer")
    #expect(identity?.serverEpoch != before.serverEpoch)
    // 与启动恢复相同的对账方式：终端仍挂在（换了二进制的）服务上，PID 不变。
    let resolution = await coordinator.reconcileAsync(
      references: [terminal.reference], persistedServerEpoch: nil)
    guard case .attached(let status) = resolution[terminal.reference] else {
      Issue.record("终端应仍在运行：\(String(describing: resolution[terminal.reference]))")
      return
    }
    #expect(status.pid == terminal.pid)
  }

  @Test func outdatedServerPromptDeclinedKeepsTheServiceAndItsTerminals() async throws {
    #expect(FileManager.default.isExecutableFile(atPath: runtimeBinaryPath()))
    let fixture = try outdatedServerWithTerminal(session: "prompt-no")
    defer { stopService(fixture.coordinator) }
    var asked = 0
    let original = ManagedTerminalCoordinator.confirmOutdatedServerRestart
    ManagedTerminalCoordinator.confirmOutdatedServerRestart = { _ in asked += 1; return false }
    defer { ManagedTerminalCoordinator.confirmOutdatedServerRestart = original }

    let identity = await fixture.coordinator.connectAsync()
    #expect(identity?.serverEpoch == fixture.epoch)
    // 选了「以后再说」，本次运行再连也不再问。
    _ = await fixture.coordinator.connectAsync()
    #expect(asked == 1)
    let resolution = await fixture.coordinator.reconcileAsync(
      references: [fixture.terminal], persistedServerEpoch: fixture.epoch)
    if case .attached = resolution[fixture.terminal] {} else {
      Issue.record("终端应仍挂在原服务上：\(String(describing: resolution[fixture.terminal]))")
    }
  }
}
