// agent 主机终端与工作区控制面隔离：它不在任何标签里，session.snapshot 与 pane.* 都碰不到它。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("agent 主机终端不出现在 session.snapshot，也无法被 pane.* 定位")
@MainActor
func agentHostTerminalIsInvisibleToPaneMethods() async throws {
  let workspace = try ControlTestWorkspace()
  defer { workspace.tearDown() }
  let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
  bridge.activeModelProvider = { [weak model = workspace.model] in model }
  bridge.attach(model: workspace.model)
  let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") {
    AsterControlDispatcher.Policy(allowSendKeys: true, allowSensitiveSessions: true, shell: AsterConfiguration().shell)
  }
  let before = bridge.allPanes().count

  // 生产实现：独立 TerminalSession，不挂进窗口就不会创建 surface，也不会启动 aster-ssh。
  let surface = LiveAgentHostTerminalSurface(hostID: UUID(), preferences: workspace.preferences)
  defer { surface.terminate() }

  #expect(bridge.allPanes().count == before)
  #expect(!bridge.allPanes().contains { $0.session === surface.session })
  let snapshot = try #require(await dispatcher.handle(controlRequest("session.snapshot"), client: ControlFakeClient()).result)
    .decoded(as: SessionSnapshot.self)
  let paneCount = snapshot.windows.flatMap(\.tabs).flatMap(\.panes).count
  #expect(paneCount == before)
  // 即便知道会话的 UUID，也不能当 pane selector 用。
  let send = await dispatcher.handle(
    controlRequest("pane.send_text", ["pane": .string(surface.session.id.uuidString), "text": "id"]),
    client: ControlFakeClient())
  #expect(send.error?.code == .notFound)
}
