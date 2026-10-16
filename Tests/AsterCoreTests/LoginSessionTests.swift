import Foundation
import Testing

@testable import AsterCore

/// 登录会话核对：识别活过注销的本机后台服务。

@Test func loginSessionReportsCurrentAuditSession() {
  // 测试进程总在某个登录会话里；拿不到说明系统调用接错了结构体。
  #expect(LoginSession.current != nil)
}

@Test func loginSessionTreatsDifferentSessionAsStale() {
  #expect(LoginSession.isStale(server: 0x186b1, current: 0x1960c))
  #expect(!LoginSession.isStale(server: 0x1960c, current: 0x1960c))
}

@Test func loginSessionKeepsServiceWhenEitherSideIsUnknown() {
  // 旧版服务不报会话、或本进程查询失败时，不能据此停掉一个可能正常的服务。
  #expect(!LoginSession.isStale(server: nil, current: 0x1960c))
  #expect(!LoginSession.isStale(server: 0x186b1, current: nil))
}

@Test func managedSessionDecoderReadsLoginSession() throws {
  let target: [String: Any] = [
    "serverID": "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8",
    "serverEpoch": "48922fa9-96c1-47ae-b68e-884fcc7bd272",
    "sessionID": "83dfae3a-991d-4f16-8e69-ddaca142b563",
  ]
  func identity(_ result: [String: Any]) throws -> SessionServerIdentity {
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "response", "operation": "server.status", "target": target, "result": result,
    ])
    return try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: MachineProfile.localProfileID,
      from: try ManagedSessionReplyDecoder.envelope(String(decoding: data, as: UTF8.self)))
  }
  #expect(try identity(["version": "0.1.0-dev", "loginSession": 0x1960c]).loginSession == 0x1960c)
  // 旧版服务没有该字段。
  #expect(try identity(["version": "0.1.0-dev"]).loginSession == nil)
}
