import Foundation
import Testing

@testable import AsterCore

// 测 SSHKnownHostsQuery：从已保存主机推导 known-hosts 列表请求（文件并集、匹配主机、名称对照）。

/// 测：每台主机与它的跳板都进 match；knownHostsFiles 按跳取并集；旧机器 target 也算；名称按 host:port 汇总。
@Test func sshKnownHostsQueryCollectsHostsJumpsAndFiles() {
  let bastion = SSHHostProfile(name: "bastion", host: "jump.example.com", knownHostsFiles: ["/kh/jump"])
  let web = SSHHostProfile(
    name: "web", host: "10.0.0.5", port: 2222, jumpHostID: bastion.id, knownHostsFiles: ["/kh/web", "/kh/jump"])
  let alias = SSHHostProfile(name: "web-alias", host: "10.0.0.5", port: 2222)
  let broken = SSHHostProfile(name: "broken", host: "")
  let (request, names) = SSHKnownHostsQuery.request(
    hosts: [.emptyDefaults(), web, bastion, alias, broken],
    machineTargets: ["root@legacy.example.com", "not a target ::"],
    homeDirectory: "/Users/tester", localUser: "tester")

  #expect(request.includeDefault && request.includeGlobal)
  #expect(Set(request.files) == ["/kh/jump", "/kh/web"])
  #expect(request.files.count == 2)
  #expect(
    request.match == [
      SSHHostPort(host: "jump.example.com", port: 22),
      SSHHostPort(host: "10.0.0.5", port: 2222),
      SSHHostPort(host: "legacy.example.com", port: 22),
    ])
  #expect(names[SSHHostPort(host: "10.0.0.5", port: 2222)] == ["web", "web-alias"])
  #expect(names[SSHHostPort(host: "jump.example.com", port: 22)] == ["bastion"])
  #expect(names[SSHHostPort(host: "legacy.example.com", port: 22)] == [])
}

/// 测：列表 JSON 与 PROTOCOL.md 的样例形状一致，null 字段解码成 nil。
@Test func sshKnownHostsListingDecodesProtocolSample() throws {
  let json = """
    {"files":[{"path":"/Users/me/.ssh/known_hosts","exists":true,"writable":true,"global":false,"error":null}],
     "entries":[{"file":"/Users/me/.ssh/known_hosts","line":3,"marker":null,"hosts":["10.0.0.5","[db]:2222"],
       "hashed":false,"algorithm":"ssh-ed25519","fingerprint":"SHA256:x","comment":null,
       "matches":[{"host":"10.0.0.5","port":22}],"lineDigest":"ab"}],
     "skipped":[{"file":"/Users/me/.ssh/known_hosts","line":9,"reason":"malformed"}]}
    """
  let listing = try JSONDecoder().decode(SSHKnownHostsListing.self, from: Data(json.utf8))
  #expect(listing.files.first?.error == nil)
  #expect(listing.entries.first?.marker == nil)
  #expect(listing.entries.first?.matches == [SSHHostPort(host: "10.0.0.5", port: 22)])
  #expect(listing.skipped.first?.reason == "malformed")
}
