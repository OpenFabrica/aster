// agent 终端里的执行行为：等输入 → host.wait、超时返回 running、中断、排队与上限、终端结束、
// 非原生连接拒绝、会话隔离。终端是模拟 Shell 的替身。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Suite("agent 远程执行：执行与等待")
@MainActor
struct AgentHostExecutionTests {
  /// 已批准（本会话）的夹具。
  private func approvedFixture(
    hostNames: [String] = ["prod-db"], configure: @escaping (FakeShellSurface) -> Void = { _ in }
  ) -> AgentHostFixture {
    let fixture = AgentHostFixture(hostNames: hostNames, configure: configure)
    fixture.approvals.nextAnswer = .allowSession
    return fixture
  }

  @Test("等输入：exec 返回 needs_input 与提示；用户回答后 host.wait 完成；审计 pending 后 finished")
  func needsInputThenWait() async throws {
    let fixture = approvedFixture { $0.behavior = { _ in .prompt("[sudo] password for deploy:") } }
    let first = try #require(await fixture.call("host.exec", AgentHostFixture.exec("sudo ls")).result)
      .decoded(as: HostExecResult.self)
    #expect(first.status == .needsInput)
    #expect(first.prompt == "[sudo] password for deploy:")
    #expect(fixture.surfaces.presenters.values.first?.attentions == 1)
    // 用户在面板里输入口令。
    _ = fixture.surfaces.byHost.values.first?.send("hunter2\r")
    let waited = try #require(
      await fixture.call("host.wait", ["command_id": .string(first.commandID), "agent": ["session": "s1"]]).result
    ).decoded(as: HostExecResult.self)
    #expect(waited.status == .completed)
    #expect(waited.exitCode == 0)
    #expect(fixture.audit.actions == [.grantCreated, .execStarted, .execPending, .execFinished])
    #expect(!fixture.audit.records.contains { $0.command?.contains("hunter2") == true })
  }

  @Test("期限到达：返回 running 与已有输出（不杀命令）；中断后记 interrupted 并在下一条命令前重新同步")
  func timeoutThenInterrupt() async throws {
    let fixture = approvedFixture { surface in
      surface.behavior = { $0 == "sleep 100" ? .hang("tick") : .complete(output: "ok", exitCode: 0) }
    }
    let running = try #require(await fixture.call("host.exec", AgentHostFixture.exec("sleep 100", timeoutMs: 300)).result)
      .decoded(as: HostExecResult.self)
    #expect(running.status == .running)
    #expect(running.output == "tick")
    let interrupted = try #require(
      await fixture.call("host.interrupt", ["command_id": .string(running.commandID), "agent": ["session": "s1"]]).result
    ).decoded(as: HostExecResult.self)
    #expect(interrupted.status == .interrupted)
    #expect(interrupted.exitCode == nil)
    let next = try #require(await fixture.call("host.exec", AgentHostFixture.exec("echo ok")).result)
      .decoded(as: HostExecResult.self)
    #expect(next.output == "ok")
    #expect(fixture.audit.records.last?.result?.status == "completed")
  }

  @Test("一个终端一次一条：期限内轮不到 → pane_busy 点名挡路命令；排队超过 4 条 → limit_exceeded")
  func busyAndQueueLimit() async throws {
    let fixture = approvedFixture { $0.behavior = { _ in .hang("") } }
    let blocker = try #require(await fixture.call("host.exec", AgentHostFixture.exec("long", timeoutMs: 200)).result)
      .decoded(as: HostExecResult.self)
    let busy = await fixture.call("host.exec", AgentHostFixture.exec("next", timeoutMs: 200))
    #expect(busy.error?.code == .paneBusy)
    #expect(busy.error?.message.contains(blocker.commandID) == true)
    let terminal = try #require(fixture.service.registry.terminals.first)
    var waiting: [Task<Void, Never>] = []
    for _ in 0..<AgentHostTerminal.maximumQueueDepth {
      waiting.append(Task { _ = try? await terminal.execute(command: "q", commandID: "c-q", deadline: .now + .seconds(2), maximumOutputBytes: 10) {} })
    }
    try await Task.sleep(for: .milliseconds(50))
    let overflow = await fixture.call("host.exec", AgentHostFixture.exec("one more", timeoutMs: 200))
    #expect(overflow.error?.code == .limitExceeded)
    waiting.forEach { $0.cancel() }
  }

  @Test("每会话最多 4 个终端")
  func terminalLimitPerSession() async {
    let names = (1...5).map { "h\($0)" }
    let fixture = approvedFixture(hostNames: names)
    for name in names.prefix(4) {
      fixture.approvals.nextAnswer = .allowSession
      #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", host: name)).error == nil)
    }
    fixture.approvals.nextAnswer = .allowSession
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", host: "h5")).error?.code == .limitExceeded)
  }

  @Test("终端结束：运行中的命令记 ended；之后 host.exec 新建终端")
  func terminalEnded() async throws {
    let fixture = approvedFixture { $0.behavior = { _ in .hang("half") } }
    let running = try #require(await fixture.call("host.exec", AgentHostFixture.exec("job", timeoutMs: 200)).result)
      .decoded(as: HostExecResult.self)
    fixture.surfaces.byHost.values.first?.isProcessRunning = false
    let ended = try #require(
      await fixture.call("host.wait", ["command_id": .string(running.commandID), "agent": ["session": "s1"], "timeout_ms": 1_000]).result
    ).decoded(as: HostExecResult.self)
    #expect(ended.status == .ended)
    #expect(fixture.audit.records.last?.result?.status == "ended")
    let next = try #require(await fixture.call("host.exec", AgentHostFixture.exec("job", timeoutMs: 200)).result)
      .decoded(as: HostExecResult.self)
    #expect(next.terminalID != running.terminalID)
  }

  @Test("前台不是 aster-ssh（回退成本地 Shell）：host_not_ready，绝不敲命令")
  func refusesLocalFallback() async {
    let fixture = approvedFixture { $0.isNativeSSHClient = false }
    let response = await fixture.call("host.exec", AgentHostFixture.exec("whoami", timeoutMs: 500))
    #expect(response.error?.code == .hostNotReady)
    #expect(fixture.surfaces.byHost.values.first?.commands.isEmpty == true)
    // 回退出来的本地 Shell 被立即结束，连预填的 ssh 命令也不留。
    #expect(fixture.surfaces.byHost.values.first?.terminated == true)
  }

  @Test("会话隔离：别的会话拿不到 command_id、读不到屏、关不掉终端")
  func sessionIsolation() async throws {
    let fixture = approvedFixture { $0.behavior = { _ in .hang("secret output") } }
    let running = try #require(await fixture.call("host.exec", AgentHostFixture.exec("job", timeoutMs: 200)).result)
      .decoded(as: HostExecResult.self)
    let intruder: JSONValue = ["session": "s2"]
    #expect(await fixture.call("host.wait", ["command_id": .string(running.commandID), "agent": intruder]).error?.code == .notFound)
    #expect(await fixture.call("host.read", ["terminal_id": .string(running.terminalID), "agent": intruder]).error?.code == .notFound)
    #expect(await fixture.call("host.close", ["host": "prod-db", "agent": intruder]).error?.code == .notFound)
    let own = try #require(await fixture.call("host.read", ["host": "prod-db", "agent": ["session": "s1"], "lines": 2]).result)
      .decoded(as: HostReadResult.self)
    #expect(own.text.contains("secret output"))
    let list = try #require(await fixture.call("host.terminals", ["agent": intruder]).result).decoded(as: HostTerminalsResult.self)
    #expect(list.terminals.isEmpty)
    #expect(await fixture.call("host.close", ["host": "prod-db", "agent": ["session": "s1"]]).error == nil)
    #expect(fixture.surfaces.byHost.values.first?.terminated == true)
  }

  @Test("全屏程序占着终端：重新同步前拒绝，不敲任何东西")
  func alternateScreenBlocksResync() async throws {
    let fixture = approvedFixture()
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    let surface = try #require(fixture.surfaces.byHost.values.first)
    surface.screen += "\nvim screen"
    surface.isAlternateScreenActive = true
    let response = await fixture.call("host.exec", AgentHostFixture.exec("ls"))
    #expect(response.error?.code == .paneBusy)
    #expect(surface.commands == ["true"])
  }
}
