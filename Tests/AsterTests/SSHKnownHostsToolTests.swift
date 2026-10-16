// SSHKnownHostsTool 与真实 aster-ssh 的 `known-hosts list / remove` JSON 契约。
// 真实二进制由 `./scripts/build-ssh-runtime.sh .build/debug` 或 cargo 构建；都不存在时跳过。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 开发构建里的 aster-ssh：先找 `swift build` 旁边的副本，再找 cargo 产物。
private let builtKnownHostsRuntime: URL? = {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  return ["/.build/debug/aster-ssh", "/SshRuntime/target/debug/aster-ssh"]
    .map { URL(fileURLWithPath: root.path + $0) }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

@Test("已知主机：与真实 aster-ssh 的 list / remove JSON 契约一致", .enabled(if: builtKnownHostsRuntime != nil))
func knownHostsToolMatchesRuntimeContract() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AsterKnownHosts-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("known_hosts")
  let key = "AAAAC3NzaC1lZDI1NTE5AAAAIJmLmI1nkfI/3D2I3aaRwGnRhxfr1FWz0KbSheixhiju"
  try "web.example.com,10.0.0.5 ssh-ed25519 \(key)\nother.example.com ssh-ed25519 \(key)\n"
    .write(to: file, atomically: true, encoding: .utf8)
  let tool = SSHRuntimeTool(executableURL: try #require(builtKnownHostsRuntime))

  let listing = try await tool.listKnownHosts(
    SSHKnownHostsListRequest(
      files: [file.path], includeDefault: false, includeGlobal: false,
      match: [SSHHostPort(host: "10.0.0.5", port: 22)]))
  let entry = try #require(listing.entries.first)
  #expect(listing.entries.count == 2)
  #expect(entry.hosts == ["web.example.com", "10.0.0.5"])
  #expect(entry.matches == [SSHHostPort(host: "10.0.0.5", port: 22)])
  #expect(entry.fingerprint.hasPrefix("SHA256:"))

  // 多主机行只删其中一台：改写成剩下的主机名。
  let result = try await tool.removeKnownHost(
    SSHKnownHostsRemoveRequest(
      file: entry.file, line: entry.line, lineDigest: entry.lineDigest, host: SSHHostPort(host: "10.0.0.5", port: 22)))
  #expect(result.removed == "pattern")
  #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("web.example.com ssh-ed25519"))

  // 行已改过，旧摘要不再匹配。
  await #expect(throws: SSHKnownHostsToolError.stale) {
    try await tool.removeKnownHost(
      SSHKnownHostsRemoveRequest(file: entry.file, line: entry.line, lineDigest: entry.lineDigest))
  }
}
