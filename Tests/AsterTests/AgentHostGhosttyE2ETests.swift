// 端到端：在真实 Ghostty surface 上跑本地 sh / bash / zsh（交互、带行编辑），用 AgentHostTerminal 的
// 真实注入与读屏路径验证标记符协议：回显、软折行、PS2 续行、退出码、状态保留、等输入与
// 用户半行输入被 Ctrl-U 清掉。远端 SSH 只是把同样的字节转给远端 Shell，协议本身在这里验证。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 本地 Shell 版本的终端适配：与生产实现相同的读写入口，只是不经 SSH。
@MainActor
private final class LocalShellSurface: AgentHostTerminalSurface {
  let session: TerminalSession
  init(session: TerminalSession) { self.session = session }
  func send(_ text: String) -> Bool { session.sendAutomationBytes(Array(text.utf8)) }
  func readActiveScreen() -> String? { session.readActiveScreenText() }
  func readScrollback(maximumLines: Int) -> String? {
    session.readControlText(includeScrollback: true, maximumLines: maximumLines)
  }
  var isProcessRunning: Bool { session.statusIsRunning }
  var isNativeSSHClient: Bool? { true }
  var isAlternateScreenActive: Bool { session.isAlternateScreenActive }
  func terminate() { session.stop(immediately: true) }
}

/// 后代视图。
private extension NSView {
  var agentHostDescendants: [NSView] { subviews + subviews.flatMap(\.agentHostDescendants) }
}

@Test("Ghostty + 交互 Shell：标记符协议在真实终端里取回输出与退出码", arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
@MainActor
func agentHostFramingAgainstRealGhosttyShell(shell: String) async throws {
  _ = NSApplication.shared
  let suite = "AgentHostGhosttyE2ETests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.autocompleteOnDeviceLearning = false
  preferences.setCompatibilityValue(.string(shell), forKey: "general.shell")
  // 不能把测试命令写进开发者真实的 Shell 历史：bash/sh 忽略空格开头的行（注入行都以空格开头），
  // zsh 指向空的 ZDOTDIR，不读用户 rc，也就没有 HISTFILE。环境只在启动 Shell 时读取一次。
  let zdotdir = FileManager.default.temporaryDirectory.appendingPathComponent("aster-e2e-zdotdir-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
  // LC_ALL=C 复现远端 C locale：bash readline 此时把 0x80 以上的字节当 Meta 键，
  // 非 ASCII 命令必须以转义形式注入才能原样到达 Shell。
  let previous = ["HISTCONTROL", "HISTFILE", "ZDOTDIR", "LC_ALL"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
  setenv("LC_ALL", "C", 1)
  setenv("HISTCONTROL", "ignorespace", 1)
  setenv("HISTFILE", "/dev/null", 1)
  setenv("ZDOTDIR", zdotdir.path, 1)
  defer {
    for (key, value) in previous {
      if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
    try? FileManager.default.removeItem(at: zdotdir)
  }
  let session = TerminalSession(workingDirectory: "/tmp")
  let host = session.makeTerminalHost(preferences: preferences)
  let view = try #require(([host] + host.agentHostDescendants).compactMap { $0 as? GhosttySurfaceView }.first)
  // 窄窗口：长输出必然软折行，验证读屏把折行接回一行。
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
  host.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host)
  window.makeKeyAndOrderFront(nil)
  view.createSurface()
  defer {
    window.orderOut(nil)
    session.stop(immediately: true)
  }
  for _ in 0..<150 where !view.isProcessRunning { try await Task.sleep(for: .milliseconds(20)) }
  #expect(view.isProcessRunning)

  let terminal = AgentHostTerminal(
    terminalID: "t-e2e", hostID: UUID(), hostName: "local", target: "local", sessionKey: "e2e",
    caller: AgentHostResolvedCaller(key: "e2e", session: "e2e"), surface: LocalShellSurface(session: session),
    timing: .init(poll: .milliseconds(50), connectQuiet: 0.5, probeTimeout: 3, probeAttempts: 3, resyncTimeout: 3,
      needsInputQuiet: 1, interruptGrace: 1))
  terminal.start()
  try await terminal.waitUntilReady(deadline: .now + .seconds(15))

  /// 执行一条命令并等结果。
  func run(_ command: String, seconds: Int = 10) async throws -> HostExecResult {
    try await terminal.execute(
      command: command, commandID: "c-\(UUID().uuidString.prefix(8))", deadline: .now + .seconds(seconds),
      maximumOutputBytes: 64 * 1_024) {}
  }

  let simple = try await run("printf 'hello\\n'; echo \"it's\"")
  #expect(simple.status == .completed)
  #expect(simple.exitCode == 0)
  #expect(simple.output == "hello\nit's")

  let failing = try await run("false")
  #expect(failing.exitCode == 1)

  let wide = try await run("printf '%0300d\\n' 0")
  #expect(wide.output == String(repeating: "0", count: 300), "软折行应被接回一行：\(wide.output.debugDescription)")

  let multiline = try await run("echo first\necho second")
  #expect(multiline.output == "first\nsecond")

  // 中文、®（含 0xAE，C locale 下的 M-.）、ˈ（含 0x88）与 emoji 原样到达并原样输出。
  let utf8 = try await run("printf '%s\\n' '中文 ® ˈ é 🚀'")
  #expect(utf8.status == .completed)
  #expect(utf8.output == "中文 ® ˈ é 🚀", "\(shell): \(utf8.output.debugDescription)")

  _ = try await run("cd /tmp && export ASTER_E2E=kept")
  let state = try await run("printf '%s %s' \"$(pwd -P)\" \"$ASTER_E2E\"")
  #expect(state.output == "/private/tmp kept")

  // 用户在提示符上留了半行没提交：Ctrl-U 清掉它，命令照常执行。
  #expect(session.sendAutomationBytes(Array("garbage-not-submitted".utf8)))
  try await Task.sleep(for: .milliseconds(200))
  let afterGarbage = try await run("echo clean")
  #expect(afterGarbage.output == "clean")

  // 等输入：read 等一行；返回 needs_input，用户回答后 wait 完成。
  let prompt = try await run("printf 'Continue? '; read answer; echo \"got $answer\"")
  #expect(prompt.status == .needsInput)
  #expect(prompt.prompt == "Continue?")
  #expect(session.sendAutomationBytes(Array("yes\r".utf8)))
  let answered = try await terminal.wait(
    commandID: prompt.commandID, deadline: .now + .seconds(10), maximumOutputBytes: 1_024,
    sinceEpisode: terminal.needsInputEpisode(of: prompt.commandID))
  #expect(answered.status == .completed)
  #expect(answered.output.hasSuffix("got yes"))

  terminal.close()
  #expect(terminal.state == .ended)
}
