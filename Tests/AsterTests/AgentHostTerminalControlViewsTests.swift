// agent 主机终端的控制遮罩与控制胶囊：遮罩生效时挡住点击和键盘焦点，胶囊上按钮以外的位置用来拖动。
import AppKit
import Testing

@testable import Aster

@MainActor
@Suite("Agent 主机终端控制视图")
struct AgentHostTerminalControlViewsTests {
  @Test("遮罩未生效时点击穿透给终端，生效后接住点击和键盘焦点，撤掉后再放行")
  func overlayBlocksInputOnlyWhileActive() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let overlay = AgentHostTerminalControlOverlay(frame: container.bounds)
    container.addSubview(overlay)
    let center = NSPoint(x: 200, y: 150)

    #expect(overlay.hitTest(center) == nil)
    #expect(!overlay.acceptsFirstResponder)

    overlay.setActive(true)
    #expect(overlay.hitTest(center) === overlay)
    #expect(overlay.acceptsFirstResponder)

    overlay.setActive(false)
    #expect(overlay.hitTest(center) == nil)
    #expect(!overlay.acceptsFirstResponder)
  }

  @Test("胶囊上的按钮照常接收点击，文字和空白处归胶囊自己用来拖动")
  func controlBarKeepsButtonsClickableAndDragsElsewhere() throws {
    let bar = AgentHostTerminalControlBar(frame: NSRect(x: 0, y: 0, width: 600, height: AgentHostTerminalControlBar.height))
    bar.interruptButton.title = "中断"
    bar.pauseButton.title = "接管"
    bar.closeButton.title = "关闭终端"
    bar.update(title: "Claude Code → prod-db", status: "正在运行：ls", tone: .active)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    container.addSubview(bar)
    bar.layoutSubtreeIfNeeded()

    let closeCenter = bar.convert(NSPoint(x: bar.closeButton.bounds.midX, y: bar.closeButton.bounds.midY), from: bar.closeButton)
    let closeHit = try #require(bar.hitTest(container.convert(closeCenter, from: bar)))
    #expect(closeHit === bar.closeButton || closeHit.isDescendant(of: bar.closeButton))

    // 左侧 30pt 处是把手和图标，不是按钮。
    #expect(bar.hitTest(container.convert(NSPoint(x: 30, y: bar.bounds.midY), from: bar)) === bar)

    var moved: CGSize?
    bar.onDrag = { moved = $0 }
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = container
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    bar.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 30, y: 20)))
    bar.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 45, y: 12)))
    #expect(moved == CGSize(width: 15, height: -8))
    bar.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 45, y: 12)))
    moved = nil
    bar.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 60, y: 12)))
    #expect(moved == nil)
  }
}
