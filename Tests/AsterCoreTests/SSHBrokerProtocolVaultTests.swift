import Foundation
import Testing

@testable import AsterCore

// 测保险库相关的控制通道字段（PROTOCOL.md §4.1 / §4.3）：privateKey 请求与 vaultKeyID 解码、
// 其它请求不带 vaultKeyID、profiles.sync 的 vaultKeys 编码。

@Test("auth.request kind=privateKey 解码出 vaultKeyID 与 interactive:false")
func sshBrokerProtocolDecodesPrivateKeyRequest() throws {
  let keyID = UUID()
  let line = Data(
    #"{"type":"auth.request","id":"a3","endpoint":"deploy@10.0.0.5:22","kind":"privateKey","hostID":null,"vaultKeyID":"\#(keyID.uuidString)","keyFile":null,"keyDigest":null,"prompts":[],"attempt":1,"interactive":false}"#
      .utf8)
  guard case .authRequest(let request) = try SSHBrokerEvent.decode(line: line) else {
    Issue.record("应解码成 authRequest")
    return
  }
  #expect(request.kind == .privateKey)
  #expect(request.vaultKeyID == keyID)
  #expect(request.interactive == false)
  #expect(request.prompts.isEmpty)
}

@Test("旧格式的口令请求没有 vaultKeyID，解码为 nil")
func sshBrokerProtocolPasswordRequestHasNoVaultKeyID() throws {
  let line = Data(
    #"{"type":"auth.request","id":"a1","endpoint":"u@h:22","kind":"password","prompts":[],"attempt":1,"interactive":true}"#
      .utf8)
  guard case .authRequest(let request) = try SSHBrokerEvent.decode(line: line) else {
    Issue.record("应解码成 authRequest")
    return
  }
  #expect(request.vaultKeyID == nil)
}

@Test("profiles.sync 带上 vaultKeys 的 id 与 publicKey")
func sshBrokerProtocolEncodesVaultKeysInProfilesSync() throws {
  let key = SSHVaultKey(
    label: "k", algorithm: "ssh-ed25519", fingerprint: "SHA256:k",
    publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA k", origin: .generated)
  let host = SSHHostProfile(name: "h", host: "10.0.0.5", vaultKeyIDs: [key.id])
  let spec = try SSHHostResolver.resolve(host.id, in: [.emptyDefaults(), host], vaultKeys: [key])
  let data = try SSHBrokerCommand.profilesSync([host.id: spec]).encodedLine()
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let profiles = try #require(object["profiles"] as? [String: [String: Any]])
  let refs = try #require(profiles[host.id.uuidString]?["vaultKeys"] as? [[String: String]])
  #expect(refs == [["id": key.id.uuidString, "publicKey": key.publicKey]])
}
