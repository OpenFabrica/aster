// agent 主机终端的两种呈现：默认停靠在调用方 Pane 底部，偏好、Pane 不在或没有定位器时用浮窗；
// 弹出 / 停靠记住选择，Pane 关闭时转浮窗且不写偏好；找回与显示的差别；注册表把这些交给每个呈现器。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("Agent 主机终端：停靠与浮窗")
struct AgentHostTerminalPresentationTests {
  /// 一个呈现器及其替身依赖。
  private struct Setup {
    let presenter: AgentHostTerminalPresenter
    let terminal: AgentHostTerminal
    let docks: AgentHostPaneDocks
    let locator: FakePaneLocator
    let preferences: AppPreferences
    let defaults: UserDefaults
    let paneID: UUID
  }

  private static let presentationKey = "aster.agent-hosts.terminal-presentation.v1"

  private func makeSetup(
    presentation: AgentHostTerminalPresentation? = nil, paneAlive: Bool = true, callerHasPane: Bool = true,
    withLocator: Bool = true
  ) -> Setup {
    let defaults = makeAgentHostTestDefaults()
    let preferences = AppPreferences(defaults: defaults)
    if let presentation { preferences.agentHostTerminalPresentation = presentation }
    let paneID = UUID()
    let locator = FakePaneLocator()
    if paneAlive { locator.alivePanes = [paneID] }
    let terminal = AgentHostTerminal(
      terminalID: "t-\(UUID().uuidString.prefix(8))", hostID: UUID(), hostName: "prod-db",
      target: "deploy@prod-db:22", sessionKey: "s1",
      caller: AgentHostResolvedCaller(key: "s1", session: "s1", paneUUID: callerHasPane ? paneID : nil),
      surface: FakeShellSurface())
    let docks = AgentHostPaneDocks()
    let presenter = AgentHostTerminalPresenter(
      terminal: terminal, hostView: NSView(), preferences: preferences, docks: docks,
      locator: withLocator ? locator : nil,
      actions: .init(interrupt: {}, togglePause: {}, focusTerminal: {}, closeTerminal: {}))
    return Setup(
      presenter: presenter, terminal: terminal, docks: docks, locator: locator, preferences: preferences,
      defaults: defaults, paneID: paneID)
  }

  /// 内容视图此刻挂在哪个父视图下。
  private func hostsContent(_ view: NSView?) -> Bool {
    view?.subviews.contains { $0 is AgentHostTerminalContentView } == true
  }

  @Test("默认停靠在调用方 Pane，浮窗不显示；偏好浮窗、agent 不在 Aster 里、Pane 已关、没有定位器都用浮窗")
  func initialPlacement() throws {
    let docked = makeSetup()
    defer { docked.presenter.close() }
    #expect(docked.presenter.placement == .docked(docked.paneID))
    #expect(hostsContent(try #require(docked.docks.mount(for: docked.paneID)).view))
    #expect(!docked.presenter.panel.window.isVisible)

    for setup in [
      makeSetup(presentation: .window), makeSetup(callerHasPane: false), makeSetup(paneAlive: false),
      makeSetup(withLocator: false),
    ] {
      #expect(setup.presenter.placement == .window)
      #expect(setup.docks.paneIDs.isEmpty)
      #expect(hostsContent(setup.presenter.panel.window.contentView))
      setup.presenter.close()
    }
  }

  @Test("弹出为独立窗口：内容搬进浮窗并记住；停靠到 Pane：搬回 Pane、记住并切过去")
  func popOutAndDockBack() throws {
    let setup = makeSetup()
    defer { setup.presenter.close() }
    let dockView = try #require(setup.docks.mount(for: setup.paneID)).view

    setup.presenter.popOut()
    #expect(setup.presenter.placement == .window)
    #expect(setup.preferences.agentHostTerminalPresentation == .window)
    #expect(setup.docks.mount(for: setup.paneID) == nil)
    #expect(!hostsContent(dockView))
    #expect(hostsContent(setup.presenter.panel.window.contentView))
    #expect(setup.presenter.panel.window.isVisible)
    #expect(setup.presenter.panel.isDockAvailable)

    setup.presenter.dockToPane()
    #expect(setup.presenter.placement == .docked(setup.paneID))
    #expect(setup.preferences.agentHostTerminalPresentation == .docked)
    #expect(!setup.presenter.panel.window.isVisible)
    #expect(setup.locator.revealedPanes == [setup.paneID])
    #expect(hostsContent(try #require(setup.docks.mount(for: setup.paneID)).view))
  }

  @Test("停靠的 Pane 关了：转成浮窗显示，不写偏好、不关终端；Pane 不在时不能再停靠")
  func paneClosedFallsBackToWindow() {
    let setup = makeSetup()
    defer { setup.presenter.close() }
    setup.locator.alivePanes = []
    setup.presenter.handlePanesClosed { !setup.locator.isPaneAlive($0) }
    #expect(setup.presenter.placement == .window)
    #expect(setup.presenter.panel.window.isVisible)
    #expect(setup.defaults.string(forKey: Self.presentationKey) == nil)
    #expect(setup.terminal.state != .ended)
    #expect(!setup.presenter.panel.isDockAvailable)

    setup.presenter.dockToPane()
    #expect(setup.presenter.placement == .window)
    #expect(setup.locator.revealedPanes.isEmpty)
  }

  @Test("显示只展开停靠区、不动窗口；找回还会切到那个 Pane；停靠时工作区窗口不算终端的浮窗")
  func showRevealAndKeyboardWhileDocked() throws {
    let setup = makeSetup()
    defer { setup.presenter.close() }
    setup.docks.setCollapsed(true, paneID: setup.paneID)
    setup.presenter.show(attention: false)
    #expect(setup.docks.state(for: setup.paneID)?.collapsed == false)
    #expect(setup.locator.revealedPanes.isEmpty)
    #expect(!setup.presenter.panel.window.isVisible)

    setup.docks.setCollapsed(true, paneID: setup.paneID)
    setup.presenter.reveal()
    #expect(setup.docks.state(for: setup.paneID)?.collapsed == false)
    #expect(setup.locator.revealedPanes == [setup.paneID])

    let workspace = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    workspace.isReleasedWhenClosed = false
    #expect(!setup.presenter.ownsKeyWindow(workspace))

    // 状态变化同步到停靠区标签。
    setup.terminal.close()
    setup.presenter.refresh()
    #expect(try #require(setup.docks.mount(for: setup.paneID)).view.tabs.first?.tone == .ended)
  }

  @Test("偏好：默认停靠，未知值按停靠；写入后读回")
  func presentationPreference() {
    let defaults = makeAgentHostTestDefaults()
    let preferences = AppPreferences(defaults: defaults)
    #expect(preferences.agentHostTerminalPresentation == .docked)
    defaults.set("floating-v0", forKey: Self.presentationKey)
    #expect(preferences.agentHostTerminalPresentation == .docked)
    preferences.agentHostTerminalPresentation = .window
    #expect(AppPreferences(defaults: defaults).agentHostTerminalPresentation == .window)
  }

  @Test("注册表把「窗口 ▸ Agent 终端」找回与 Pane 关闭交给每个呈现器")
  func registryRoutesRevealAndPaneClosure() async throws {
    let fixture = AgentHostFixture()
    fixture.approvals.nextAnswer = .allowSession
    #expect(await fixture.call("host.exec", AgentHostFixture.exec("true")).error == nil)
    let terminal = try #require(fixture.service.registry.terminals.first)
    let presenter = try #require(fixture.surfaces.presenters[terminal.hostID])
    let pane = UUID()
    presenter.dockedPaneID = pane

    fixture.service.registry.reveal(terminal.terminalID)
    #expect(presenter.revealed == 1)
    fixture.service.registry.handlePanesClosed { $0 != pane }
    #expect(presenter.dockedPaneID == pane)
    fixture.service.registry.handlePanesClosed { $0 == pane }
    #expect(presenter.dockedPaneID == nil)
  }
}
