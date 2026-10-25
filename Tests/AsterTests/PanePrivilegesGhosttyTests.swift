// 真实 Ghostty 字节链路：关闭鼠标捕获不影响其他 surface、键盘或本地滚屏。
import AppKit
import CoreGraphics
import Foundation
import Testing
@preconcurrency import GhosttyKit
@testable import Aster

@MainActor
private func privilegeWait(_ predicate: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(4))
  while ContinuousClock.now < deadline {
    if predicate() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return predicate()
}

@Test("Ghostty鼠标权限逐surface隔离，重载后仍屏蔽报告并保留键盘和滚屏")
@MainActor
func panePrivilegesGhosttyMouseIsolation() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aster-mouse-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = directory.appendingPathComponent("mouse.sh")
  try """
    /bin/stty -echo -icanon min 1 time 0
    i=0
    while [ "$i" -lt 80 ]; do printf 'line %s text for selection\\n' "$i"; i=$((i + 1)); done
    printf '\\033[?1003h\\033[?1006h'
    exec /bin/cat
    """.write(to: script, atomically: true, encoding: .utf8)
  let config = "font-size = 12\nmouse-shift-capture = always\n"
  func makeView() -> (GhosttySurfaceView, NSWindow) {
    let view = GhosttySurfaceView(workingDirectory: directory.path, environment: [:], configurationText: config)
    view.command = "/bin/sh " + script.path
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.createSurface()
    return (view, window)
  }
  let (first, firstWindow) = makeView()
  let (second, secondWindow) = makeView()
  defer { first.destroySurface(); second.destroySurface(); firstWindow.close(); secondWindow.close() }
  #expect(await privilegeWait {
    first.surface.map(ghostty_surface_mouse_captured) == true
      && second.surface.map(ghostty_surface_mouse_captured) == true
  })
  var firstBytes: [UInt8] = []
  var secondBytes: [UInt8] = []
  first.onPTYWrite = { firstBytes += $0 }
  second.onPTYWrite = { secondBytes += $0 }
  first.allowMouseCapture = false
  // 无按键的首次移动也必须被关闭；单独Shift bypass只会屏蔽按键期间的移动。
  let move = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 10, y: 20),
    modifierFlags: [], timestamp: 0, windowNumber: firstWindow.windowNumber,
    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
  first.mouseMoved(with: move)
  #expect(first.typeText("before-reload"))
  #expect(await privilegeWait { String(decoding: firstBytes, as: UTF8.self).contains("before-reload") })
  #expect(!String(decoding: firstBytes, as: UTF8.self).contains("\u{1B}[<"))
  firstBytes.removeAll()
  // 全局配置广播必须重新应用第一surface的局部覆盖，第二surface仍允许捕获。
  second.updateConfiguration(config + "font-size = 13\n")
  func click(_ view: GhosttySurfaceView, _ window: NSWindow) throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 25, y: 50),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      if type == .leftMouseDown { view.mouseDown(with: event) }
      else { view.mouseUp(with: event) }
    }
  }
  try click(first, firstWindow)
  try click(second, secondWindow)
  #expect(await privilegeWait { String(decoding: secondBytes, as: UTF8.self).contains("\u{1B}[<") })
  #expect(!String(decoding: firstBytes, as: UTF8.self).contains("\u{1B}[<"))

  let before = try #require(first.bufferInfo()).viewport_top
  let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
    wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0))
  first.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
  #expect(try #require(first.bufferInfo()).viewport_top < before)
  #expect(first.typeText("keyboard-remains"))
  #expect(await privilegeWait { String(decoding: firstBytes, as: UTF8.self).contains("keyboard-remains") })
  #expect(!String(decoding: firstBytes, as: UTF8.self).contains("\u{1B}[<"))
}
