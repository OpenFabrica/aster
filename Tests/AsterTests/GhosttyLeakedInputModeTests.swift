// 程序不清理就退出时留下的鼠标上报，应在 Shell 回到新提示符时被复位。
import AppKit
import Testing
@preconcurrency import GhosttyKit

@testable import Aster

/// 轮询等待条件成立，超时返回最后一次结果。
@MainActor
private func waitUntilTrue(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Test("命令结束后的新提示符复位残留的鼠标上报，无命令的提示符重绘不复位")
@MainActor
func ghosttyResetsLeakedMouseReportingAtNextPrompt() async throws {
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  // 第一段：打开 1003/1006 后只发提示符（模拟重绘），上报应保留；
  // 第二段：补上命令边界 C/D 再发提示符，上报应被复位。
  // libghostty 用 `exec` 启动 command，多条语句必须放进脚本文件交给 /bin/sh。
  let script = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-leaked-modes-\(UUID().uuidString).sh")
  try """
    printf '\\033[?1003h\\033[?1006h\\033]133;A\\007'
    sleep 2
    printf '\\033]133;C\\007\\033]133;D;0\\007\\033]133;A\\007'
    sleep 30
    """.write(to: script, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: script) }
  view.command = "/bin/sh " + script.path
  defer { view.destroySurface() }
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView?.addSubview(view)
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }

  func mouseCaptured() -> Bool {
    guard let surface = view.surface else { return false }
    return ghostty_surface_mouse_captured(surface)
  }

  #expect(await waitUntilTrue { mouseCaptured() })
  // 没有命令边界的提示符不能动程序或 Shell 自己的模式。
  try await Task.sleep(for: .milliseconds(300))
  #expect(mouseCaptured())
  #expect(await waitUntilTrue { !mouseCaptured() })
}
