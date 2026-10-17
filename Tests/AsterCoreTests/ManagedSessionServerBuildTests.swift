import Foundation
import Testing

@testable import AsterCore

// 后台服务构建号：解析、过期判定，以及真实服务上的「静默替换 / 交给用户决定」。

@Test func managedSessionServerBuildParsesVersionLine() {
  #expect(
    ManagedSessionServerBuild.parse(versionLine: "aster-session 0.1.0-dev protocol=1.0 build=e19229a5\n")
      == "e19229a5")
  #expect(ManagedSessionServerBuild.parse(versionLine: "aster-session 0.1.0-dev protocol=1.0\n") == nil)
  #expect(ManagedSessionServerBuild.parse(versionLine: "other 1.0 build=abc") == nil)
  #expect(ManagedSessionServerBuild.parse(versionLine: "aster-session 0.1.0-dev build=") == nil)
}

@Test func managedSessionServerBuildOutdatedOnlyWhenBundledBuildIsKnown() {
  #expect(ManagedSessionServerBuild.isOutdated(server: "a", bundled: "b"))
  // 加入构建号之前的旧服务不报构建号，也算旧服务。
  #expect(ManagedSessionServerBuild.isOutdated(server: nil, bundled: "b"))
  #expect(!ManagedSessionServerBuild.isOutdated(server: "b", bundled: "b"))
  // App 侧未知时不比较，避免误停正常服务。
  #expect(!ManagedSessionServerBuild.isOutdated(server: "a", bundled: nil))
  #expect(!ManagedSessionServerBuild.isOutdated(server: nil, bundled: ""))
}

@Test func managedSessionServerIdentityDecodesBuild() throws {
  let json: [String: Any] = [
    "target": ["serverID": "s", "serverEpoch": "e", "sessionID": "n"],
    "result": ["version": "0.1.0-dev", "build": "e19229a5"],
  ]
  let identity = try ManagedSessionReplyDecoder.serverIdentity(
    machineProfileID: MachineProfile.localProfileID, from: json)
  #expect(identity.build == "e19229a5")
}

// MARK: - 真实服务

/// 本仓库构建出的运行时（不带构建号）。缺失即判失败，不静默跳过。
private func runtimeBinaryPath() -> String {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
}

/// 私有状态目录，加一个冒充「新版 App 自带二进制」的包装脚本：`--version` 报一个
/// 不同的构建号，其余命令原样转给真实运行时。真实服务不带构建号，所以它总是旧服务。
private func makeUpgradeFixture() throws -> (stateParent: URL, wrapper: String) {
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
  return (directory, wrapper)
}

@Test func outdatedServerWithoutRunningTerminalsIsReplacedSilently() throws {
  #expect(FileManager.default.isExecutableFile(atPath: runtimeBinaryPath()))
  let fixture = try makeUpgradeFixture()
  let endpoint = ManagedSessionEndpoint(
    machineProfileID: MachineProfile.localProfileID, binaryPath: fixture.wrapper,
    stateParentPath: fixture.stateParent.path, sessionName: "build-idle")
  let client = LocalManagedSessionClient()
  defer { try? client.stopServer(endpoint) }
  _ = try client.ensureServer(endpoint)
  let before = try client.serverStatus(endpoint)

  let bundled = ManagedSessionServerBuild.bundled(binaryPath: fixture.wrapper, client: client)
  #expect(bundled == "newer")
  let attachment = try client.ensureCurrentServer(endpoint, bundledBuild: bundled)
  #expect(attachment.outdatedRunningTerminals == 0)
  #expect(attachment.identity.serverEpoch != before.serverEpoch)
}

@Test func outdatedServerWithRunningTerminalIsLeftForTheUserToDecide() throws {
  #expect(FileManager.default.isExecutableFile(atPath: runtimeBinaryPath()))
  let fixture = try makeUpgradeFixture()
  let endpoint = ManagedSessionEndpoint(
    machineProfileID: MachineProfile.localProfileID, binaryPath: fixture.wrapper,
    stateParentPath: fixture.stateParent.path, sessionName: "build-busy")
  let client = LocalManagedSessionClient()
  defer { try? client.stopServer(endpoint) }
  _ = try client.ensureServer(endpoint)
  let before = try client.serverStatus(endpoint)
  let terminal = try client.createTerminal(
    endpoint, workingDirectory: "/tmp", argv: ["/bin/sh", "-c", "sleep 30"])

  let attachment = try client.ensureCurrentServer(endpoint, bundledBuild: "newer")
  #expect(attachment.outdatedRunningTerminals == 1)
  #expect(attachment.identity.serverEpoch == before.serverEpoch)
  let live = try client.listTerminals(endpoint)
  #expect(live.contains { $0.reference == terminal.reference && $0.state == .running })
}
