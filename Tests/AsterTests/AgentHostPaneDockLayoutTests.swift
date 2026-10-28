// 停靠区接入 Pane 与工作区：在 Pane 宿主里贴底、排在 Prompt Queue 下面并按规则定高；旧宿主不再碰它；
// 工作区整树重建后装回停靠区、焦点留在停靠区里，点停靠区不算点 Pane，收起与撤掉只局部重装。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("Agent 主机终端：停靠区接入 Pane 与工作区")
struct AgentHostPaneDockLayoutTests {
  private static let expanded = ActivePaneHostView.DockHeight(
    ratio: 0.4, minimum: 200, contentReserve: 100, collapsedHeight: nil)

  private func makeHost(height: CGFloat) -> (ActivePaneHostView, NSView) {
    let host = ActivePaneHostView(paneID: UUID(), isActive: true, onExternalDrop: { _, _ in false }) {}
    host.frame = NSRect(x: 0, y: 0, width: 400, height: height)
    let content = NSView()
    host.installContent(content)
    return (host, content)
  }

  /// 装进窗口的 Pane 宿主：和工作区里一样，宿主尺寸由外层固定，停靠区约束不能把它撑大。
  private func makeWindowedHost(height: CGFloat) -> (NSWindow, ActivePaneHostView, NSView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: height), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    let (host, content) = makeHost(height: height)
    window.contentView = host
    return (window, host, content)
  }

  @Test("停靠区贴 Pane 底边、在 Prompt Queue 下面：按比例、不低于最小高度、给内容留够；收起只剩头部；撤掉后内容回到底边")
  func hostStacksDockBelowPromptQueue() {
    let (window, host, content) = makeWindowedHost(height: 1_000)
    defer { window.close() }
    let accessory = NSView()
    accessory.translatesAutoresizingMaskIntoConstraints = false
    accessory.heightAnchor.constraint(equalToConstant: 44).isActive = true
    host.setBottomAccessory(accessory)
    let dock = NSView()
    host.setAgentHostDock(dock, height: Self.expanded)
    host.layoutSubtreeIfNeeded()
    #expect(dock.frame == NSRect(x: 0, y: 0, width: 400, height: 400))
    #expect(abs(accessory.frame.minY - (dock.frame.maxY + 8)) < 0.5)
    #expect(abs(content.frame.minY - (accessory.frame.maxY + 8)) < 0.5)

    // 比例给的高度（160）低于最小值时取最小值。
    window.setContentSize(NSSize(width: 400, height: 400))
    host.layoutSubtreeIfNeeded()
    #expect(abs(dock.frame.height - 200) < 0.5)
    // 再矮就先保住内容的 100pt：300 - 100 - (8 + 44 + 8) = 140；Pane 本身不被撑高。
    window.setContentSize(NSSize(width: 400, height: 300))
    host.layoutSubtreeIfNeeded()
    #expect(host.frame.height == 300)
    #expect(abs(content.frame.height - 100) < 0.5)
    #expect(abs(dock.frame.height - 140) < 0.5)
    #expect(abs(content.frame.maxY - 300) < 0.5)

    var collapsed = Self.expanded
    collapsed.collapsedHeight = AgentHostPaneDockView.headerHeight
    host.setAgentHostDock(dock, height: collapsed)
    host.layoutSubtreeIfNeeded()
    #expect(dock.frame.height == AgentHostPaneDockView.headerHeight)

    host.setBottomAccessory(nil)
    host.setAgentHostDock(nil, height: nil)
    host.layoutSubtreeIfNeeded()
    #expect(dock.superview == nil)
    #expect(content.frame == host.bounds)
  }

  @Test("插件 pane.bottom 条贴左右边，排在内容与 Prompt Queue 之间；条没有项目时高度归零；撤掉后内容回到原位")
  func hostStacksExtensionBarAboveAccessory() {
    let (window, host, content) = makeWindowedHost(height: 1_000)
    defer { window.close() }
    let accessory = NSView()
    accessory.translatesAutoresizingMaskIntoConstraints = false
    accessory.heightAnchor.constraint(equalToConstant: 44).isActive = true
    host.setBottomAccessory(accessory)
    let dock = NSView()
    host.setAgentHostDock(dock, height: Self.expanded)
    let bar = NSView()
    host.setExtensionBar(bar, height: 24)
    host.layoutSubtreeIfNeeded()
    #expect(dock.frame == NSRect(x: 0, y: 0, width: 400, height: 400))
    #expect(abs(accessory.frame.minY - (dock.frame.maxY + 8)) < 0.5)
    #expect(bar.frame == NSRect(x: 0, y: accessory.frame.maxY + 8, width: 400, height: 24))
    #expect(abs(content.frame.minY - bar.frame.maxY) < 0.5)
    #expect(host.installedExtensionBar === bar)

    // ToolBarView 自带高度约束：没有项目时隐藏并归零，内容直接接到 Prompt Queue 上方。
    let toolBar = ToolBarView(slot: .paneBottom, height: 24)
    host.setExtensionBar(toolBar)
    host.layoutSubtreeIfNeeded()
    #expect(bar.superview == nil)
    #expect(toolBar.isHidden)
    #expect(abs(content.frame.minY - (accessory.frame.maxY + 8)) < 0.5)
    toolBar.apply(segments: [
      ToolBarSegment(id: "p/view:bar", pluginName: "P", iconPath: nil, content: .items([ToolBarItem(text: "x")]),
        runningSince: nil)
    ])
    host.layoutSubtreeIfNeeded()
    #expect(abs(toolBar.frame.height - InterfaceScale.length(24)) < 0.5)
    #expect(abs(content.frame.minY - toolBar.frame.maxY) < 0.5)

    // 条被新的 host 接走后，旧 host 撤槽不碰它。
    let (other, _) = makeHost(height: 600)
    other.setExtensionBar(toolBar)
    host.setExtensionBar(nil)
    #expect(toolBar.superview === other)
    host.setAgentHostDock(nil, height: nil)
    host.setBottomAccessory(nil)
    host.layoutSubtreeIfNeeded()
    #expect(content.frame == host.bounds)
  }

  @Test("停靠区被新的 Pane 宿主接走后，旧宿主重建约束或撤槽都不再碰它")
  func staleHostLeavesDockAlone() {
    let (old, _) = makeHost(height: 600)
    let (new, _) = makeHost(height: 1_000)
    let dock = NSView()
    old.setAgentHostDock(dock, height: Self.expanded)
    new.setAgentHostDock(dock, height: Self.expanded)
    #expect(dock.superview === new)

    // 旧宿主还记着停靠区：重建约束链时跳过它，撤槽时也不把它从新宿主里摘走。
    old.setBottomAccessory(NSView())
    old.setAgentHostDock(nil, height: nil)
    #expect(dock.superview === new)
    #expect(old.constraints.allSatisfy { $0.firstItem !== dock && $0.secondItem !== dock })
    new.layoutSubtreeIfNeeded()
    #expect(abs(dock.frame.height - 400) < 0.5)
  }

  @Test("工作区：停靠区随 Pane 装回，重建后焦点留在停靠区；点停靠区不算点 Pane；收起与撤掉局部重装")
  func workspaceKeepsDockAndFocusAcrossRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.path
    let first = PaneDescriptor(kind: .fileBrowser, workingDirectory: directory)
    let second = PaneDescriptor(kind: .fileBrowser, workingDirectory: directory)
    let defaults = makeAgentHostTestDefaults()
    let layout = PaneLayout.split(axis: .horizontal, first: .leaf(first), second: .leaf(second), ratio: 0.5)
    let tab = WorkspaceTabSnapshot(id: UUID(), title: "Dock", layout: layout)
    defaults.set(
      try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
      forKey: "aster.workspace.snapshot.v1")
    let model = AppModel(defaults: defaults)
    let preferences = AppPreferences(defaults: defaults)
    model.ensureInitialTab()
    let docks = AgentHostPaneDocks()
    let workspace = WorkspaceViewController(model: model, preferences: preferences, agentHostDocks: docks)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = workspace
    window.contentView?.layoutSubtreeIfNeeded()
    defer { window.close() }

    let content = AgentHostFocusableView()
    docks.attach(agentHostDockItem("t1", content: content), to: first.id)
    let dock = try #require(docks.mount(for: first.id)).view
    /// 等工作区不再重建：停靠区连续 150ms 留在同一个宿主里。首次加载会连着刷新几次，每次都排一个异步回焦，
    /// 没等完就设焦点会被它们抢走——那是测试时序，不是停靠区的行为。
    func settle() async throws {
      var host = dock.superview
      var stableSince = ContinuousClock.now
      let deadline = ContinuousClock.now + .seconds(5)
      while ContinuousClock.now - stableSince < .milliseconds(150), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        if dock.superview !== host {
          host = dock.superview
          stableSince = .now
        }
      }
    }
    try await settle()
    let firstHost = try #require(dock.superview as? ActivePaneHostView)
    #expect(firstHost.paneID == first.id)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(dock.frame.height >= AgentHostPaneDocks.minimumExpandedHeight)
    #expect(window.makeFirstResponder(content))
    #expect(WorkspaceViewController.paneHost(forClickOn: content) == nil)
    #expect(WorkspaceViewController.paneHost(forClickOn: dock) == nil)
    #expect(WorkspaceViewController.paneHost(forClickOn: firstHost) === firstHost)

    // 整树重建：新的 Pane 宿主接走停靠区，焦点同步还给停靠区里的视图，异步回焦也不抢走。
    model.objectWillChange.send()
    await pollUntil { dock.superview !== firstHost && dock.superview is ActivePaneHostView }
    #expect((dock.superview as? ActivePaneHostView)?.paneID == first.id)
    try await settle()
    #expect(window.firstResponder === content)

    docks.setCollapsed(true, paneID: first.id)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(dock.frame.height == AgentHostPaneDockView.headerHeight)
    docks.detach("t1")
    #expect(dock.superview == nil)
  }
}
