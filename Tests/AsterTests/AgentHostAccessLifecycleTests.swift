// 终端列表不泄露会话键、关开关与撤销授权后终端随之关闭、前台进程未确认时绝不敲字。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Suite("agent 远程执行：访问生命周期")
@MainActor
struct AgentHostAccessLifecycleTests {
  /// 已批准（本会话）并跑过一条命令的夹具。
  private func connectedFixture(session: String = "s1") async -> AgentHostFixture {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowSession
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", session: session)).error == nil)
    return fixture
  }

  @Test("host.terminals 必须带 agent，只列本会话，结果里没有会话键")
  func terminalsOmitSessionKeys() async throws {
    let fixture = await connectedFixture()
    #expect(await fixture.call("host.terminals", [:]).error?.code == .invalidParams)
    let response = await fixture.call("host.terminals", ["agent": ["session": "s1"]])
    let raw = try #require(response.result)
    #expect(try raw.decoded(as: HostTerminalsResult.self).terminals.count == 1)
    let text = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
    #expect(!text.contains("\"session\""))
    #expect(!text.contains("s1"))
  }

  @Test("关掉总开关：关闭全部 agent 终端，读屏返回 agent_access_disabled")
  func disablingClosesTerminals() async throws {
    let fixture = await connectedFixture()
    let surface = try #require(fixture.surfaces.byHost.values.first)
    fixture.surfaces.enabled = false
    fixture.service.handleAccessDisabled()
    #expect(surface.terminated)
    #expect(fixture.service.registry.terminals.isEmpty)
    let read = await fixture.call("host.read", ["host": "prod-db", "agent": ["session": "s1"]])
    #expect(read.error?.code == .agentAccessDisabled)
  }

  @Test("撤销 session 授权只关该会话的终端；撤销 always 关这台主机的全部终端")
  func revokingClosesTerminals() async throws {
    let fixture = await connectedFixture()
    let user = AgentHostLocalUser(account: "tester", name: "T")
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", session: "s2")).error == nil)
    #expect(fixture.service.registry.terminals.count == 2)
    let s2Grant = try #require(fixture.service.grants.grants.first { $0.sessionKey == "s2" })
    fixture.service.grants.revoke(grantID: s2Grant.grantID, by: user)
    #expect(fixture.service.registry.terminals.map(\.sessionKey) == ["s1"])

    fixture.approvals.nextAnswer = .allowAlways
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", session: "s3")).error == nil)
    #expect(fixture.service.registry.terminals.count == 2)
    let always = try #require(fixture.service.grants.grants.first { $0.scope == .always })
    fixture.service.grants.revoke(grantID: always.grantID, by: user)
    #expect(fixture.service.registry.terminals.isEmpty)
  }

  @Test("前台进程判断不了（nil）：不发探针、不敲命令，到期 host_not_ready")
  func unverifiedForegroundNeverTyped() async throws {
    let fixture = AgentHostFixture { $0.isNativeSSHClient = nil }
    fixture.approvals.nextAnswer = .allowSession
    let response = await fixture.call("host.exec", AgentHostFixture.exec("whoami", timeoutMs: 300))
    #expect(response.error?.code == .hostNotReady)
    let surface = try #require(fixture.surfaces.byHost.values.first)
    #expect(surface.commands.isEmpty)
    #expect(!surface.screen.contains("ready"))
    #expect(!surface.terminated)
  }

  @Test("连上之后前台变得无法确认：下一条命令 host_not_ready，不敲进去")
  func reverifiesBeforeEverySend() async throws {
    let fixture = await connectedFixture()
    let surface = try #require(fixture.surfaces.byHost.values.first)
    surface.isNativeSSHClient = nil
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("ls", timeoutMs: 300)).error?.code == .hostNotReady)
    #expect(surface.commands == ["true"])
  }
}
