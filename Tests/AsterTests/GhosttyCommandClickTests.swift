import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 回归：前台程序开着鼠标上报（Claude Code 全屏即如此）时，Command 点击链接不能再写进
/// PTY。程序从 SGR 上报里看不出 Command，会当普通点击自己打开链接，浏览器在 Aster 的
/// 确认框之前就被打开。
@Test("鼠标上报开启时 Command 点击链接只交给 Aster 打开，不上报给前台程序")
@MainActor
func ghosttyCommandClickOnLinkIsNotReportedToProgram() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.commandclick.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer {
    for tab in model.tabs { tab.stop(immediately: true) }
    window.orderOut(nil)
    defaults.removePersistentDomain(forName: suite)
  }
  window.layoutIfNeeded()

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  var surfaceView: GhosttySurfaceView?
  for _ in 0..<200 {
    if let view = descendants(controller.view)
      .compactMap({ $0 as? GhosttySurfaceView }).first(where: { $0.surface != nil }),
      view.isProcessRunning
    {
      surfaceView = view
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  let view = try #require(surfaceView, "工作区终端未启动")

  // 打开 X10 + SGR 鼠标上报后用 sleep 占住前台：sleep 不读 stdin，提示符不回来，
  // 鼠标模式也就不会被新提示符复位。
  let url = "https://example.com/aster-command-click"
  #expect(view.typeText("printf '\\n%s\\n\\033[?1000h\\033[?1006h' '\(url)'; sleep 30\n"))
  var rendered = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.split(separator: "\n").contains(where: {
      $0.trimmingCharacters(in: .whitespaces) == url
    }) == true { rendered = true; break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(rendered, "等待实际输出行，不能把回显的 printf 命令当成链接已经显示")
  var linkPoint: NSPoint?
  search: for y in stride(from: 4.0, to: view.bounds.height, by: 8.0) {
    for x in stride(from: 4.0, to: view.bounds.width, by: 8.0) {
      let candidate = NSPoint(x: x, y: view.bounds.maxY - y)
      if view.inlineLinkTarget(at: candidate)?.text == url {
        linkPoint = candidate
        break search
      }
    }
  }
  let point = try #require(linkPoint, "视口内找不到可点击的 URL")

  var written: [UInt8] = []
  view.onPTYWrite = { written.append(contentsOf: $0) }
  var opened: [String] = []
  view.onRequestOpenTarget = { target, _ in opened.append(target) }

  func mouse(
    _ type: NSEvent.EventType, at local: NSPoint, _ flags: NSEvent.ModifierFlags
  ) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: view.convert(local, to: nil), modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  }
  /// 依次取出 PTY 中的 SGR 鼠标上报（`ESC [ < b ; x ; y M/m`，去掉前缀，如 `0;12;5M`）。
  func reports() -> [String] {
    let text = String(decoding: written, as: UTF8.self)
    var found: [String] = []
    var rest = text[...]
    while let start = rest.range(of: "\u{1b}[<") {
      rest = rest[start.upperBound...]
      guard let end = rest.firstIndex(where: { $0 == "M" || $0 == "m" }) else { break }
      found.append(String(rest[...end]))
      rest = rest[rest.index(after: end)...]
    }
    return found
  }
  /// 等到满足条件的上报到达；上报经 IO 线程写 PTY 再回主线程，不能立即读取。
  func waitForReports(until done: ([String]) -> Bool) async throws {
    for _ in 0..<150 where !done(reports()) {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  // 正向对照：链接处的普通点击必须写成一对上报，证明上报确已开启、观测通道有效。
  view.mouseDown(with: try mouse(.leftMouseDown, at: point, []))
  view.mouseUp(with: try mouse(.leftMouseUp, at: point, []))
  try await waitForReports { $0.count >= 2 }
  let linkClick = reports()
  try #require(linkClick.count == 2 && linkClick[0].hasSuffix("M") && linkClick[1].hasSuffix("m"),
    "普通点击应作为鼠标上报写入 PTY")

  // Command 点击后在别的单元格补一次普通点击作栅栏：PTY 写入有序，等到栅栏的抬起，
  // Command 点击若被上报必然已经排在前面。
  written.removeAll()
  let far = NSPoint(x: point.x + 40, y: point.y)
  view.mouseDown(with: try mouse(.leftMouseDown, at: point, [.command]))
  #expect(!view.leftMouseReleasePending, "Aster 接管的 Command 点击不能向 Ghostty 发 PRESS")
  view.mouseUp(with: try mouse(.leftMouseUp, at: point, [.command]))
  view.mouseDown(with: try mouse(.leftMouseDown, at: far, []))
  view.mouseUp(with: try mouse(.leftMouseUp, at: far, []))
  try await waitForReports { $0.last.map { $0.hasSuffix("m") && $0 != linkClick[1] } == true }
  let fence = reports()
  #expect(fence.count == 2, "Command 点击链接不能上报给前台程序：\(fence)")
  #expect(!fence.contains(linkClick[0]) && !fence.contains(linkClick[1]))
  try await Task.sleep(for: .milliseconds(20))
  #expect(opened == [url], "Command 点击应只由 Aster 请求打开一次")

  // Command 拖出阈值是拖选：手势还给 Ghostty，在原按下位置补发 PRESS，程序收到成对的
  // 按下与抬起，也不打开链接。
  written.removeAll()
  opened.removeAll()
  view.mouseDown(with: try mouse(.leftMouseDown, at: point, [.command]))
  view.mouseDragged(with: try mouse(.leftMouseDragged, at: far, [.command]))
  view.mouseUp(with: try mouse(.leftMouseUp, at: far, [.command]))
  try await waitForReports { $0.count >= 2 }
  try await Task.sleep(for: .milliseconds(50))
  #expect(reports() == [linkClick[0], fence[1]], "拖选应把按下位置与抬起位置都交给前台程序")
  #expect(opened.isEmpty, "拖选不能打开链接")
  #expect(!view.leftMouseReleasePending)
}
