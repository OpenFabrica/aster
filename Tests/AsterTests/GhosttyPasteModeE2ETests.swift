// 在真实 Ghostty surface 上验证 Aster ABI v3 的终端模式字段：粘贴保护依赖它们判断
// 程序是否开启 bracketed paste、是否处在备用屏。
import AppKit
import Foundation
@preconcurrency import GhosttyKit
import Testing

@testable import Aster
import AsterCore

private extension NSView {
  var pasteModeDescendants: [NSView] {
    subviews + subviews.flatMap(\.pasteModeDescendants)
  }
}

/// 挂一个运行中的 Ghostty Pane；关闭 copy-on-select，避免改写用户剪贴板。
@MainActor
private func makeRunningSurface() async throws -> (TerminalSession, NSWindow, GhosttySurfaceView) {
  _ = NSApplication.shared
  let suite = "GhosttyPasteModeE2ETests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.autocompleteOnDeviceLearning = false
  preferences.configuration.controls.copyOnSelect = false
  let session = TerminalSession(workingDirectory: "/tmp")
  let host = session.makeTerminalHost(preferences: preferences)
  let view = try #require(
    ([host] + host.pasteModeDescendants).compactMap { $0 as? GhosttySurfaceView }.first)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  host.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host)
  window.makeKeyAndOrderFront(nil)
  view.createSurface()
  for _ in 0..<100 where !view.isProcessRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  return (session, window, view)
}

/// 轮询直到终端模式满足条件；Shell 输出经 IO 线程解析，需要等待。
@MainActor
private func waitForMode(
  _ view: GhosttySurfaceView,
  _ matches: (ghostty_aster_buffer_info_s) -> Bool
) async throws -> Bool {
  for _ in 0..<150 {
    if let info = view.bufferInfo(), matches(info) { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return false
}

@Test("buffer_info 报告程序开启的 bracketed paste 与备用屏")
@MainActor
func ghosttyBufferInfoReportsPasteRelevantModes() async throws {
  let (session, window, view) = try await makeRunningSurface()
  defer {
    window.orderOut(nil)
    session.stop(immediately: true)
  }
  #expect(view.isProcessRunning)

  // 一条命令完成开、关两个阶段：`read` 等测试发回车再关闭模式，sleep 让结果保持到断言结束。
  // 不在两阶段之间发 Ctrl-C：SIGINT 会让 tty 丢弃紧随其后的输入，第二条命令可能整条丢失。
  #expect(
    view.typeText(
      "printf '\\033[?2004h\\033[?1049h'; read -r _; printf '\\033[?1049l\\033[?2004l'; sleep 30\n"
    ))
  #expect(try await waitForMode(view) { $0.bracketed_paste && $0.alternate_screen })

  #expect(view.typeText("\n"))
  #expect(try await waitForMode(view) { !$0.bracketed_paste && !$0.alternate_screen })
  view.sendInterrupt()
}
