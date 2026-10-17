import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 旧后台服务仍有终端在运行：并发连接只问一次，同意才替换，拒绝就保持原服务和终端。

/// 本仓库构建出的运行时（不带构建号）。
private func runtimeBinaryPath() -> String {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
}

/// 私有状态目录与冒充新版自带二进制的包装脚本（`--version` 报另一个构建号）。
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

/// 两个用例都替换同一个静态提示回调，必须串行，否则会互相覆盖。
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
