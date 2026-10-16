import AsterCore
import Foundation
import Testing

@testable import Aster

// 设置页「已知主机」桥接：加载状态、快照形状、删除请求只接受上一次列表里的可写记录、
// stale 时提示并重新加载，以及与真实 aster-ssh 的 JSON 契约。

/// 假的 aster-ssh：记录请求，按预设返回列表或删除结果。
private actor FakeKnownHostsTool {
  var listing = SSHKnownHostsListing()
  var removeError: Error?
  private(set) var listRequests: [SSHKnownHostsListRequest] = []
  private(set) var removeRequests: [SSHKnownHostsRemoveRequest] = []

  /// 设置下一次列表结果。
  func setListing(_ value: SSHKnownHostsListing) { listing = value }
  /// 设置删除时抛出的错误；nil 表示成功。
  func setRemoveError(_ error: Error?) { removeError = error }

  /// 记录请求并返回预设列表。
  func list(_ request: SSHKnownHostsListRequest) -> SSHKnownHostsListing {
    listRequests.append(request)
    return listing
  }

  /// 记录请求，按预设成功或失败。
  func remove(_ request: SSHKnownHostsRemoveRequest) throws -> SSHKnownHostsRemoveResult {
    removeRequests.append(request)
    if let removeError { throw removeError }
    return SSHKnownHostsRemoveResult(removed: request.host == nil ? "line" : "pattern")
  }
}

/// 一份带可写默认文件与只读系统文件的列表。
private func sampleListing() -> SSHKnownHostsListing {
  SSHKnownHostsListing(
    files: [
      .init(path: "/tmp/kh/known_hosts", exists: true, writable: true, global: false),
      .init(path: "/etc/ssh/ssh_known_hosts", exists: true, writable: false, global: true),
    ],
    entries: [
      .init(
        file: "/tmp/kh/known_hosts", line: 1, hosts: ["10.0.0.5", "web.example.com"],
        algorithm: "ssh-ed25519", fingerprint: "SHA256:abc",
        matches: [SSHHostPort(host: "10.0.0.5", port: 22)], lineDigest: "d1"),
      .init(
        file: "/etc/ssh/ssh_known_hosts", line: 3, hosts: ["(hashed)"], hashed: true,
        algorithm: "ssh-rsa", fingerprint: "SHA256:def", lineDigest: "d2"),
    ],
    skipped: [.init(file: "/tmp/kh/known_hosts", line: 2, reason: "malformed")])
}

/// 测试夹具：假工具、固定主机与记录到的 toast / 推送次数。
@MainActor
private final class KnownHostsFixture {
  let fake = FakeKnownHostsTool()
  let bridge: SettingsKnownHostsBridge
  var toasts: [(text: String, isError: Bool)] = []
  var pushes = 0

  init(hosts: [SSHHostProfile] = [], machineTargets: [String] = []) {
    let fake = fake
    bridge = SettingsKnownHostsBridge(
      dependencies: .init(
        list: { await fake.list($0) },
        remove: { try await fake.remove($0) }),
      hosts: { [.emptyDefaults()] + hosts },
      machineTargets: { machineTargets })
    bridge.toast = { [unowned self] in self.toasts.append(($0, $1)) }
    bridge.pushSnapshot = { [unowned self] in self.pushes += 1 }
  }

  /// 执行动作并等待回执。
  func perform(_ action: String, _ payload: [String: Any] = [:]) async -> Bool {
    await withCheckedContinuation { continuation in
      let handled = bridge.handle(action: action, payload: payload) { continuation.resume(returning: $0) }
      if !handled { continuation.resume(returning: false) }
    }
  }

  /// 等到状态满足条件（最多约 3 秒）。
  func waitFor(_ condition: (SettingsKnownHostsBridge.State) -> Bool) async {
    for _ in 0..<300 where !condition(bridge.state) {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

@Test("已知主机：首次为 idle；刷新先推 loading，再推带主机名与可删标记的列表")
@MainActor
func knownHostsRefreshBuildsSnapshot() async throws {
  let web = SSHHostProfile(name: "web", host: "10.0.0.5", knownHostsFiles: ["/tmp/kh/extra"])
  let fixture = KnownHostsFixture(hosts: [web], machineTargets: ["deploy@legacy.example.com:2222"])
  await fixture.fake.setListing(sampleListing())
  #expect(fixture.bridge.snapshot()["state"] as? String == "idle")

  #expect(await fixture.perform("hosts.knownHosts.refresh") == true)
  #expect(fixture.pushes == 2)
  let request = try #require(await fixture.fake.listRequests.first)
  #expect(request.files == ["/tmp/kh/extra"])
  #expect(request.includeDefault && request.includeGlobal)
  #expect(request.match == [SSHHostPort(host: "10.0.0.5", port: 22), SSHHostPort(host: "legacy.example.com", port: 2222)])

  let snapshot = fixture.bridge.snapshot()
  #expect(snapshot["state"] as? String == "loaded")
  let entries = try #require(snapshot["entries"] as? [[String: Any]])
  #expect(entries.count == 2)
  #expect(entries[0]["names"] as? [[String]] == [["web"]])
  #expect(entries[0]["removable"] as? Bool == true)
  #expect(entries[1]["removable"] as? Bool == false)
  let files = try #require(snapshot["files"] as? [[String: Any]])
  #expect(files[1]["global"] as? Bool == true)
  #expect((snapshot["skipped"] as? [[String: Any]])?.first?["reason"] as? String == "malformed")
}

@Test("已知主机：只删除上一次列表里可写文件中的记录；主机必须是列表显示过的命中项")
@MainActor
func knownHostsRemoveValidatesAgainstListing() async throws {
  let fixture = KnownHostsFixture()
  await fixture.fake.setListing(sampleListing())
  // 还没有列表时一律拒绝。
  #expect(await fixture.perform("hosts.knownHosts.remove", ["file": "/tmp/kh/known_hosts", "line": 1, "lineDigest": "d1"]) == false)
  #expect(await fixture.perform("hosts.knownHosts.refresh") == true)

  let rejected: [[String: Any]] = [
    ["file": "/etc/ssh/ssh_known_hosts", "line": 3, "lineDigest": "d2"],  // 系统级只读
    ["file": "/tmp/other", "line": 1, "lineDigest": "d1"],  // 不在列表里
    ["file": "/tmp/kh/known_hosts", "line": 1, "lineDigest": "zz"],  // 摘要不符
    ["file": "/tmp/kh/known_hosts", "line": 1, "lineDigest": "d1", "host": ["host": "evil", "port": 22]],
    ["file": "/tmp/kh/known_hosts", "line": "1", "lineDigest": "d1"],
  ]
  for payload in rejected {
    #expect(await fixture.perform("hosts.knownHosts.remove", payload) == false, "\(payload)")
  }
  #expect(await fixture.fake.removeRequests.isEmpty)
  #expect(fixture.toasts.count == rejected.count + 1)

  let accepted = await fixture.perform(
    "hosts.knownHosts.remove",
    ["file": "/tmp/kh/known_hosts", "line": 1, "lineDigest": "d1", "host": ["host": "10.0.0.5", "port": 22]])
  #expect(accepted == true)
  #expect(
    await fixture.fake.removeRequests == [
      SSHKnownHostsRemoveRequest(
        file: "/tmp/kh/known_hosts", line: 1, lineDigest: "d1", host: SSHHostPort(host: "10.0.0.5", port: 22))
    ])
  // 删除后自动重新列出。
  await fixture.waitFor { $0 == .loaded }
  #expect(await fixture.fake.listRequests.count == 2)
}

@Test("已知主机：记录已被改过（stale）时 toast 提示并重新加载")
@MainActor
func knownHostsRemoveStaleReloads() async throws {
  let fixture = KnownHostsFixture()
  await fixture.fake.setListing(sampleListing())
  #expect(await fixture.perform("hosts.knownHosts.refresh") == true)
  await fixture.fake.setRemoveError(SSHKnownHostsToolError.stale)

  #expect(
    await fixture.perform("hosts.knownHosts.remove", ["file": "/tmp/kh/known_hosts", "line": 1, "lineDigest": "d1"])
      == false)
  #expect(fixture.toasts.last?.isError == true)
  await fixture.waitFor { $0 == .loaded }
  #expect(await fixture.fake.listRequests.count == 2)
}

@Test("已知主机：主机桥把 hosts.knownHosts.* 转给协作者，快照带 knownHosts")
@MainActor
func knownHostsRoutedThroughHostsBridge() throws {
  let fixture = try HostsBridgeFixture()
  defer { fixture.cleanUp() }
  #expect((fixture.bridge.snapshot()["knownHosts"] as? [String: Any])?["state"] as? String == "idle")
  #expect(fixture.bridge.knownHosts.handle(action: "hosts.knownHosts.bogus", payload: [:]) { _ in } == false)
  #expect(fixture.perform("hosts.knownHosts.bogus", [:]) == false)
  #expect(fixture.recorder.toasts.last?.isError == true)
}

/// 开发构建里的 aster-ssh：先找 `swift build` 旁边的副本，再找 cargo 产物。
private let builtAsterSSH: URL? = {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  return ["/.build/debug/aster-ssh", "/SshRuntime/target/debug/aster-ssh"]
    .map { URL(fileURLWithPath: root.path + $0) }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

@Test("已知主机：与真实 aster-ssh 的 list / remove JSON 契约一致", .enabled(if: builtAsterSSH != nil))
func knownHostsToolMatchesRuntimeContract() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AsterKnownHosts-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("known_hosts")
  let key = "AAAAC3NzaC1lZDI1NTE5AAAAIJmLmI1nkfI/3D2I3aaRwGnRhxfr1FWz0KbSheixhiju"
  try "web.example.com,10.0.0.5 ssh-ed25519 \(key)\nother.example.com ssh-ed25519 \(key)\n"
    .write(to: file, atomically: true, encoding: .utf8)
  let tool = SSHRuntimeTool(executableURL: try #require(builtAsterSSH))

  let listing = try await tool.listKnownHosts(
    SSHKnownHostsListRequest(
      files: [file.path], includeDefault: false, includeGlobal: false,
      match: [SSHHostPort(host: "10.0.0.5", port: 22)]))
  let entry = try #require(listing.entries.first)
  #expect(listing.entries.count == 2)
  #expect(entry.hosts == ["web.example.com", "10.0.0.5"])
  #expect(entry.matches == [SSHHostPort(host: "10.0.0.5", port: 22)])
  #expect(entry.fingerprint.hasPrefix("SHA256:"))

  let result = try await tool.removeKnownHost(
    SSHKnownHostsRemoveRequest(
      file: entry.file, line: entry.line, lineDigest: entry.lineDigest, host: SSHHostPort(host: "10.0.0.5", port: 22)))
  #expect(result.removed == "pattern")
  #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("web.example.com ssh-ed25519"))

  await #expect(throws: SSHKnownHostsToolError.stale) {
    try await tool.removeKnownHost(
      SSHKnownHostsRemoveRequest(file: entry.file, line: entry.line, lineDigest: entry.lineDigest))
  }
}
