import Foundation
import Testing

@testable import AsterCore

// 测主机配置里的保险库引用：旧 JSON 兼容、继承默认项、找不到的 ID 跳过、跳板每一跳各自解析、
// 规格 JSON 在没有保险库密钥时与改造前一致；以及主机存储对 vaultKeyIDs 的规范化与校验。

/// 一把保险库密钥。
private func vaultKey(_ seed: String) -> SSHVaultKey {
  SSHVaultKey(
    label: seed, algorithm: "ssh-ed25519", fingerprint: "SHA256:\(seed)",
    publicKey: "ssh-ed25519 \(Data(seed.utf8).base64EncodedString()) \(seed)", origin: .generated)
}

@Test("旧版 hosts.json 没有 vaultKeyIDs 也能解码，值为 nil")
func sshHostProfileDecodesWithoutVaultKeyIDs() throws {
  let json = #"{"id":"6F1A0C3E-8D7B-4A44-9C55-0B1C2D3E4F50","name":"old","group":null,"host":"h","user":"","identityFiles":[],"forwards":[]}"#
  let profile = try JSONDecoder().decode(SSHHostProfile.self, from: Data(json.utf8))
  #expect(profile.vaultKeyIDs == nil)
}

@Test("保险库密钥：主机留空继承默认项，自己写了就覆盖；找不到的 ID 跳过")
func sshHostResolverResolvesVaultKeys() throws {
  let a = vaultKey("a")
  let b = vaultKey("b")
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", vaultKeyIDs: [a.id])
  let inherits = SSHHostProfile(name: "inherits", host: "10.0.0.1")
  let overrides = SSHHostProfile(name: "overrides", host: "10.0.0.2", vaultKeyIDs: [UUID(), b.id])
  let hosts = [defaults, inherits, overrides]

  let inherited = try SSHHostResolver.resolve(inherits.id, in: hosts, vaultKeys: [a, b])
  #expect(inherited.vaultKeys == [a.reference])
  let own = try SSHHostResolver.resolve(overrides.id, in: hosts, vaultKeys: [a, b])
  #expect(own.vaultKeys == [b.reference])
  // 没给目录（或密钥都已删除）时不产生空数组。
  #expect(try SSHHostResolver.resolve(inherits.id, in: hosts).vaultKeys == nil)
}

@Test("保险库密钥：跳板每一跳按自己的配置解析")
func sshHostResolverResolvesVaultKeysPerHop() throws {
  let jumpKey = vaultKey("jump")
  let targetKey = vaultKey("target")
  let jump = SSHHostProfile(name: "bastion", host: "bastion", vaultKeyIDs: [jumpKey.id])
  let target = SSHHostProfile(
    name: "db", host: "db", jumpHostID: jump.id, vaultKeyIDs: [targetKey.id])
  let spec = try SSHHostResolver.resolve(
    target.id, in: [.emptyDefaults(), jump, target], vaultKeys: [jumpKey, targetKey])
  #expect(spec.vaultKeys == [targetKey.reference])
  #expect(spec.jump?.spec.vaultKeys == [jumpKey.reference])
}

@Test("规格 JSON：有保险库密钥时带 vaultKeys，没有时不出现该键")
func sshResolvedSpecEncodesVaultKeysOnlyWhenPresent() throws {
  let key = vaultKey("a")
  let host = SSHHostProfile(name: "h", host: "h", vaultKeyIDs: [key.id])
  let hosts = [SSHHostProfile.emptyDefaults(), host]
  let with = try JSONEncoder().encode(try SSHHostResolver.resolve(host.id, in: hosts, vaultKeys: [key]))
  let object = try #require(JSONSerialization.jsonObject(with: with) as? [String: Any])
  let refs = try #require(object["vaultKeys"] as? [[String: Any]])
  #expect(refs.first?["id"] as? String == key.id.uuidString)
  #expect(refs.first?["publicKey"] as? String == key.publicKey)

  let without = try JSONEncoder().encode(try SSHHostResolver.resolve(host.id, in: hosts))
  #expect(!String(decoding: without, as: UTF8.self).contains("vaultKeys"))
}

@Test("主机存储：空 vaultKeyIDs 规范化成 nil，重复引用与超量被拒，悬空 ID 允许")
func sshHostStoreValidatesVaultKeyIDs() {
  let id = UUID()
  let empty = SSHHostProfile(name: "e", host: "e", vaultKeyIDs: [])
  #expect(SSHHostStore.normalized([empty])[1].vaultKeyIDs == nil)
  let dangling = SSHHostProfile(name: "d", host: "d", vaultKeyIDs: [UUID()])
  #expect(SSHHostStore.validate(SSHHostStore.normalized([dangling])).isEmpty)
  let duplicated = SSHHostProfile(name: "x", host: "x", vaultKeyIDs: [id, id])
  #expect(SSHHostStore.validate(SSHHostStore.normalized([duplicated])) == ["[1] invalid vaultKeyIDs"])
  let tooMany = SSHHostProfile(
    name: "y", host: "y", vaultKeyIDs: (0...SSHHostStore.maximumVaultKeys).map { _ in UUID() })
  #expect(SSHHostStore.validate(SSHHostStore.normalized([tooMany])) == ["[1] invalid vaultKeyIDs"])
}
