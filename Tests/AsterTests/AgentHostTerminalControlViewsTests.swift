// agent 主机终端的控制遮罩与控制胶囊：遮罩生效时挡住点击和键盘焦点，胶囊上按钮以外的位置用来拖动。
import AppKit
import Testing

@testable import Aster

@MainActor
@Suite("Agent 主机终端控制视图")
struct AgentHostTerminalControlViewsTests {
  @Test("长命令、主机名与接管状态变化不会移动胶囊和按钮，窄窗口仍可操作")
  func controlBarStaysInPlaceAcrossContentChanges() throws {
    let bar = AgentHostTerminalControlBar()
    bar.interruptButton.title = "中断"
    bar.pauseButton.title = "接管"
    bar.closeButton.title = "关闭终端"
    let content = AgentHostTerminalContentView(controlBar: bar, hostView: NSView(), focusTerminal: {})
    let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    defer { window.close() }

    for width: CGFloat in [760, 420] {
      window.setContentSize(NSSize(width: width, height: 460))
      bar.pauseButton.title = "接管"
      bar.update(title: "claude-code → 算力服务器", status: "空闲", tone: .idle)
      content.needsLayout = true
      content.layoutSubtreeIfNeeded()
      bar.layoutSubtreeIfNeeded()
      let initialFrame = bar.frame
      let buttons = [bar.interruptButton, bar.pauseButton, bar.closeButton]
      let initialButtons = buttons.map { bar.convert($0.bounds, from: $0) }

      for (title, status, tone, pauseTitle) in [
        ("claude-code → 算力服务器", "正在运行：" + String(repeating: "systemctl status milo-tts && ", count: 20), AgentHostTerminalControlBar.Tone.active, "接管"),
        (String(repeating: "production-host-", count: 20), "等待你的输入：请直接在下面的终端里回答", .attention, "接管"),
        ("claude-code → 算力服务器", "空闲 · agent 已暂停", .paused, "交还 agent"),
        ("claude-code → 算力服务器", "空闲", .idle, "接管"),
      ] {
        bar.pauseButton.title = pauseTitle
        bar.update(title: title, status: status, tone: tone)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        #expect(bar.frame == initialFrame)
        #expect(buttons.map { bar.convert($0.bounds, from: $0) } == initialButtons)
        #expect(content.bounds.contains(bar.frame))
        for button in buttons {
          let rect = bar.convert(button.bounds, from: button)
          #expect(bar.bounds.contains(rect))
          #expect(rect.width >= button.intrinsicContentSize.width)
          let hit = try #require(bar.hitTest(content.convert(NSPoint(x: rect.midX, y: rect.midY), from: bar)))
          #expect(hit === button || hit.isDescendant(of: button))
        }
      }
      bar.onDrag?(CGSize(width: -100, height: 140))
      content.layoutSubtreeIfNeeded()
      let draggedFrame = bar.frame
      #expect(draggedFrame.origin.y > initialFrame.origin.y)
      bar.update(title: "远端主机", status: String(repeating: "长命令输出", count: 100), tone: .active)
      content.needsLayout = true
      content.layoutSubtreeIfNeeded()
      #expect(bar.frame == draggedFrame)
      window.setContentSize(NSSize(width: 420, height: 220))
      content.layoutSubtreeIfNeeded()
      #expect(content.bounds.contains(bar.frame))
    }
  }

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
