// agent 主机终端的关闭快捷键：⌘W / ⌥⌘W 只收起拥有键盘的那个终端，终端照常运行，
// 别的窗口是 key 时交还工作区处理。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("Agent 主机终端：关闭快捷键")
struct AgentHostCloseShortcutTests {
  @Test("关闭快捷键只交给浮窗是 key 的那个终端，终端不关；别的窗口是 key 时不处理")
  func closeShortcutGoesToOwningPresenterOnly() async throws {
    let fixture = AgentHostFixture(hostNames: ["prod-db", "web1"])
    fixture.approvals.nextAnswer = .allowSession
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", host: "prod-db")).error == nil)
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true", host: "web1")).error == nil)
    let prodID = try #require(fixture.hosts.first { $0.name == "prod-db" }?.id)
    let webID = try #require(fixture.hosts.first { $0.name == "web1" }?.id)
    let prod = try #require(fixture.surfaces.presenters[prodID])
    let web = try #require(fixture.surfaces.presenters[webID])
    let panel = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    let workspace = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    workspace.isReleasedWhenClosed = false
    web.ownedWindow = panel
    let registry = fixture.service.registry

    #expect(registry.ownsKeyWindow(panel))
    #expect(!registry.ownsKeyWindow(workspace))
    #expect(registry.handleCloseShortcut(in: panel))
    #expect(web.hiddenByShortcut == 1)
    #expect(prod.hiddenByShortcut == 0)
    #expect(!registry.handleCloseShortcut(in: workspace))
    #expect(web.hiddenByShortcut == 1)
    // 收起不是关闭：两个终端都还在，agent 可以继续用。
    #expect(registry.terminals.count == 2)
    #expect(registry.terminals.allSatisfy { $0.state != .ended })
    #expect(!web.closed)
  }

  @Test("真实浮窗：关闭快捷键只把它藏起来，终端照常运行；终端结束后才真正关窗")
  func panelHidesOnCloseShortcutUntilEnded() throws {
    let surface = FakeShellSurface()
    let terminal = AgentHostTerminal(
      terminalID: "t-close", hostID: UUID(), hostName: "prod-db", target: "deploy@prod-db:22", sessionKey: "s1",
      caller: AgentHostResolvedCaller(key: "s1", session: "s1"), surface: surface)
    var closeRequests = 0
    let controller = AgentHostTerminalPanelController(
      terminal: terminal, hostView: NSView(), preferences: AppPreferences(defaults: makeAgentHostTestDefaults()),
      actions: .init(interrupt: {}, togglePause: {}, focusTerminal: {}, closeTerminal: { closeRequests += 1 }))
    defer { controller.close() }
    let panel = controller.window
    let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    other.isReleasedWhenClosed = false

    controller.show(attention: false)
    #expect(panel.isVisible)
    #expect(controller.ownsKeyWindow(panel))
    #expect(!controller.ownsKeyWindow(other))

    controller.hideForCloseShortcut()
    #expect(!panel.isVisible)
    #expect(terminal.state != .ended)
    #expect(!surface.terminated)
    #expect(closeRequests == 0)

    // 「窗口 ▸ Agent 终端」还能找回来。
    controller.show(attention: false)
    #expect(panel.isVisible)

    terminal.close()
    controller.hideForCloseShortcut()
    #expect(!panel.isVisible)
  }
}
