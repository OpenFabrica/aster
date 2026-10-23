// agent 主机终端停靠区：注册表按 Pane 记终端、选中与收起、高度比例夹紧、关闭快捷键收起停靠区；
// 停靠区视图只挂选中且展开的终端内容、头部按钮与拖动调高度、拒收拖放。
import AppKit
import AsterCore
import Combine
import Testing

@testable import Aster

/// 能成为第一响应者的普通视图，模拟停靠区里的终端。
@MainActor
final class AgentHostFocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

/// 一个停靠条目；内容默认是普通视图。
@MainActor
func agentHostDockItem(
  _ id: String, title: String = "prod-db", content: NSView = NSView(), popOut: @escaping @MainActor () -> Void = {}
) -> AgentHostPaneDocks.Item {
  .init(
    terminalID: id, content: content,
    tab: .init(terminalID: id, title: title, toolTip: "Claude Code → \(title)", tone: .idle), popOut: popOut)
}

@MainActor
@Suite("Agent 主机终端：Pane 停靠区")
struct AgentHostPaneDockTests {
  @Test("新终端停进 Pane 时选中并展开；摘掉最后一个时整个撤掉，并通知工作区")
  func attachSelectsAndDetachRemovesDock() throws {
    let docks = AgentHostPaneDocks()
    var changes: [UUID] = []
    let subscription = docks.changes.sink { changes.append($0) }
    defer { subscription.cancel() }
    let pane = UUID()
    #expect(docks.mount(for: pane) == nil)

    docks.attach(agentHostDockItem("t1"), to: pane)
    docks.attach(agentHostDockItem("t2", title: "web1"), to: pane)
    let state = try #require(docks.state(for: pane))
    #expect(state.terminalIDs == ["t1", "t2"])
    #expect(state.selectedID == "t2")
    #expect(!state.collapsed)
    #expect(docks.paneID(of: "t1") == pane)
    let mount = try #require(docks.mount(for: pane))
    #expect(mount.height.collapsedHeight == nil)
    #expect(mount.height.ratio == AgentHostPaneDocks.defaultHeightRatio)
    #expect(mount.height.minimum == AgentHostPaneDocks.minimumExpandedHeight)
    #expect(mount.view.tabs.map(\.title) == ["prod-db", "web1"])

    docks.detach("t2")
    #expect(docks.state(for: pane)?.selectedID == "t1")
    let host = NSView()
    host.addSubview(mount.view)
    docks.detach("t1")
    #expect(docks.mount(for: pane) == nil)
    #expect(docks.paneID(of: "t1") == nil)
    #expect(mount.view.superview == nil)
    #expect(!changes.isEmpty)
    #expect(changes.allSatisfy { $0 == pane })
  }

  @Test("收起只剩头部；选中或新命令重新展开；高度比例夹在 0.2–0.75")
  func collapseRevealAndClampHeight() throws {
    let docks = AgentHostPaneDocks()
    let pane = UUID()
    docks.attach(agentHostDockItem("t1"), to: pane)
    docks.attach(agentHostDockItem("t2"), to: pane)
    docks.setCollapsed(true, paneID: pane)
    #expect(try #require(docks.mount(for: pane)).height.collapsedHeight == AgentHostPaneDockView.headerHeight)
    docks.reveal("t1")
    let state = try #require(docks.state(for: pane))
    #expect(state.selectedID == "t1")
    #expect(!state.collapsed)

    docks.setHeightRatio(0.05, paneID: pane)
    #expect(docks.state(for: pane)?.heightRatio == AgentHostPaneDocks.heightRatioRange.lowerBound)
    docks.setHeightRatio(0.95, paneID: pane)
    #expect(docks.state(for: pane)?.heightRatio == AgentHostPaneDocks.heightRatioRange.upperBound)
    docks.setHeightRatio(0.5, paneID: pane)
    #expect(try #require(docks.mount(for: pane)).height.ratio == 0.5)
  }

  @Test("停靠区只挂选中且展开的终端，内容在头部下方；切换、收起时摘下的终端不销毁")
  func dockViewMountsOnlySelectedContent() throws {
    let docks = AgentHostPaneDocks()
    let pane = UUID()
    let first = NSView()
    let second = NSView()
    docks.attach(agentHostDockItem("t1", content: first), to: pane)
    docks.attach(agentHostDockItem("t2", content: second), to: pane)
    let view = try #require(docks.mount(for: pane)).view
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
    view.layoutSubtreeIfNeeded()
    #expect(second.superview === view)
    #expect(first.superview == nil)
    #expect(second.frame == NSRect(x: 0, y: 0, width: 600, height: 240 - AgentHostPaneDockView.headerHeight))

    docks.reveal("t1")
    #expect(first.superview === view)
    #expect(second.superview == nil)
    let deep = NSView()
    first.addSubview(deep)
    #expect(docks.paneID(containing: deep) == pane)

    docks.setCollapsed(true, paneID: pane)
    #expect(first.superview == nil)
    #expect(docks.paneID(containing: deep) == nil)
  }

  @Test("点标签切换选中，点「弹出」交给选中的终端，点「收起」只剩头部，拖头部按 Pane 高度换算比例；拒收拖放")
  func dockViewHeaderActions() throws {
    let docks = AgentHostPaneDocks()
    let pane = UUID()
    var poppedOut: [String] = []
    docks.attach(agentHostDockItem("t1", popOut: { poppedOut.append("t1") }), to: pane)
    docks.attach(agentHostDockItem("t2", title: "web1", popOut: { poppedOut.append("t2") }), to: pane)
    let view = try #require(docks.mount(for: pane)).view
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(view)
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
    view.layoutSubtreeIfNeeded()

    let tabs = view.subviews.compactMap { $0 as? AgentHostPaneDockTabButton }
    #expect(tabs.map(\.label) == ["prod-db", "web1"])
    tabs[0].performClick(nil)
    #expect(docks.state(for: pane)?.selectedID == "t1")
    #expect(tabs[0].isSelectedTab && !tabs[1].isSelectedTab)

    let icons = view.subviews.compactMap { $0 as? IconHoverButton }
    #expect(icons.count == 2)
    icons[0].performClick(nil)
    #expect(poppedOut == ["t1"])

    // 头部空白处往上拖 50pt：(200 + 50) / 500。
    func mouse(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: 400, y: y), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.mouseDown(with: mouse(.leftMouseDown, y: 190))
    view.mouseDragged(with: mouse(.leftMouseDragged, y: 240))
    view.mouseUp(with: mouse(.leftMouseUp, y: 240))
    #expect(abs((docks.state(for: pane)?.heightRatio ?? 0) - 0.5) < 0.001)
    // 头部以下（终端内容区）按下不调高度。
    view.mouseDown(with: mouse(.leftMouseDown, y: 50))
    view.mouseDragged(with: mouse(.leftMouseDragged, y: 150))
    #expect(abs((docks.state(for: pane)?.heightRatio ?? 0) - 0.5) < 0.001)

    icons[1].performClick(nil)
    #expect(docks.state(for: pane)?.collapsed == true)
    #expect(Set(view.registeredDraggedTypes).isSuperset(of: [.fileURL, .URL, .string]))
  }

  @Test("焦点在停靠区里时关闭快捷键收起停靠区并报告已处理；焦点在别处时交给工作区")
  func closeShortcutCollapsesDockOwningFocus() throws {
    let docks = AgentHostPaneDocks()
    let pane = UUID()
    let content = AgentHostFocusableView()
    docks.attach(agentHostDockItem("t1", content: content), to: pane)
    let view = try #require(docks.mount(for: pane)).view
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    let elsewhere = AgentHostFocusableView()
    window.contentView?.addSubview(view)
    window.contentView?.addSubview(elsewhere)
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
    view.layoutSubtreeIfNeeded()

    #expect(window.makeFirstResponder(content))
    #expect(docks.paneID(owningKeyboardIn: window) == pane)
    #expect(docks.handleCloseShortcut(in: window))
    #expect(docks.state(for: pane)?.collapsed == true)
    #expect(content.superview == nil)

    #expect(window.makeFirstResponder(elsewhere))
    #expect(docks.paneID(owningKeyboardIn: window) == nil)
    #expect(!docks.handleCloseShortcut(in: window))
  }
}
