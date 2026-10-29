// 显式启用的真实 Claude CLI 交互验收，使用独立后台服务与不显示的窗口。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTER_CLAUDE_PROBE_BINARY"] != nil))
@MainActor
func managedClaudeAcceptsKeyboardWithoutSnapshotLoop() async throws {
  _ = NSApplication.shared
  let environment = ProcessInfo.processInfo.environment
  let binary = try #require(environment["ASTER_CLAUDE_PROBE_BINARY"])
  let cwd = try #require(environment["ASTER_CLAUDE_PROBE_CWD"])
  let folder = URL(fileURLWithPath: "/tmp/aster-claude-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: folder) }
  try "foreground=#24292f\nbackground=#ffffff\n".write(
    to: folder.appendingPathComponent("client-colors"), atomically: true, encoding: .utf8)
  let endpoint = ManagedSessionEndpoint(
    binaryPath: binary, stateParentPath: folder.path, sessionName: "probe")
  let client = LocalManagedSessionClient()
  _ = try client.ensureServer(endpoint)
  defer { try? client.stopServer(endpoint) }
  let terminal = try client.createTerminal(
    endpoint, workingDirectory: cwd,
    argv: [environment["SHELL"] ?? "/bin/zsh", "-l", "-i"])
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1593, height: 909),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let suite = "AsterTests.claude-probe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  if let current = UserDefaults.standard.persistentDomain(forName: "io.local.aster-terminal") {
    defaults.setPersistentDomain(current, forName: suite)
  }
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  let view = GhosttySurfaceView(
    workingDirectory: cwd, environment: ["PATH": "/usr/bin:/bin"],
    configurationText: GhosttyConfiguration.make(preferences: preferences))
  view.frame = try #require(window.contentView).bounds
  view.command = GhosttyConfiguration.launchCommand(
    shell: binary, arguments: ["terminal", "attach", folder.path, "probe", terminal.reference.terminalID])
  var output = Data()
  view.onPTYRead = { output.append(contentsOf: $0) }
  window.contentView?.addSubview(view)
  defer { view.destroySurface(); window.close() }
  view.createSurface()

  func wait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while ContinuousClock.now < deadline {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(30))
    }
    print("CLAUDE_PROBE_SCREEN", view.readText(includeScrollback: false) ?? "nil")
    try #require(predicate(), "真实 Claude 画面或键盘输入未在期限内更新")
  }
  try await wait { view.readText(includeScrollback: false)?.contains("❯") == true }
  #expect(view.typeText("claude\n"))
  try await wait {
    let screen = view.readText(includeScrollback: false) ?? ""
    return screen.contains("Claude Code") && screen.contains("❯")
  }
  #expect(view.typeText("aster-text-probe"))
  try await wait { view.readText(includeScrollback: false)?.contains("aster-text-probe") == true }
  let event = try #require(NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: window.windowNumber, context: nil, characters: "g",
    charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
  view.keyDown(with: event)
  try await wait { view.readText(includeScrollback: false)?.contains("aster-text-probeg") == true }
  let before = output.count
  try await Task.sleep(for: .seconds(2))
  let suffix = Array(output.dropFirst(before))
  let resets = suffix.indices.dropLast().filter { suffix[$0] == 0x1b && suffix[$0 + 1] == 0x63 }.count
  #expect(resets < 4, "空闲时反复发送 RIS 全量快照会造成闪烁")
}
