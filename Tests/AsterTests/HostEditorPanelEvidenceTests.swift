// 主机编辑面板的口令操作显隐，以及设置了 ASTER_HOSTS_PAGE_EVIDENCE_DIR 时的明暗两套截图
// （新建、编辑、端口转发、底部操作区、默认设置）。夹具见 `HostEditorPanelTests.swift`。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 设置了 `ASTER_HOSTS_PAGE_EVIDENCE_DIR` 时截下测试窗口（文件名 `aster-editor-<name>-<明暗>.png`）。
@MainActor
private func captureEditorWindow(_ window: NSWindow, name: String) async throws {
  guard let directory = ProcessInfo.processInfo.environment["ASTER_HOSTS_PAGE_EVIDENCE_DIR"] else { return }
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(400))
  let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  capture.arguments = [
    "-x", "-o", "-l", String(window.windowNumber),
    URL(fileURLWithPath: directory).appendingPathComponent("aster-editor-\(name)-\(appearance).png").path,
  ]
  try capture.run()
  capture.waitUntilExit()
  #expect(capture.terminationStatus == 0)
}

@Test("编辑面板：编辑已有主机时异步查询口令，有口令才显示「忘记保存的口令」",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func hostEditorPasswordActionAndEvidence(appearance: NSAppearance.Name) async throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture, appearance: appearance)
  defer { window.orderOut(nil) }

  page.openEditor(.edit(fixture.full.id))
  let panel = try #require(page.editorPanel)
  let forget = try #require(panel.forgetPasswordButton)
  for _ in 0..<50 where forget.isHidden { try await Task.sleep(for: .milliseconds(20)) }
  #expect(!forget.isHidden)
  page.openEditor(.edit(fixture.jump.id))
  let other = try #require(page.editorPanel)
  try await Task.sleep(for: .milliseconds(200))
  #expect(other.forgetPasswordButton?.isHidden == true)

  guard ProcessInfo.processInfo.environment["ASTER_HOSTS_PAGE_EVIDENCE_DIR"] != nil else { return }
  page.closeEditor()
  page.createHost()
  try await captureEditorWindow(window, name: "new")
  page.closeEditor()
  page.openEditor(.edit(fixture.full.id))
  let edit = try #require(page.editorPanel)
  for section in edit.form.sections { section.setExpanded(true) }
  try await captureEditorWindow(window, name: "edit")
  // 滚到端口转发分区。
  if let forwards = hostEditorView("host-editor-section-forwards", in: edit.view),
    let scroll = forwards.enclosingScrollView, let document = scroll.documentView
  {
    let top = forwards.convert(NSPoint.zero, to: document).y
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(top - 120, 0)))
  }
  try await captureEditorWindow(window, name: "edit-forwards")
  // 滚到底部看端口转发、高级与操作区。
  if let scroll = hostEditorView("host-editor-scroll", in: edit.view) as? NSScrollView,
    let document = scroll.documentView
  {
    document.scroll(NSPoint(x: 0, y: document.bounds.height))
  }
  try await captureEditorWindow(window, name: "edit-bottom")
  page.closeEditor()
  page.openEditor(.defaults)
  try await captureEditorWindow(window, name: "defaults")
}

/// 按 identifier 递归找视图。
@MainActor
private func hostEditorView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for subview in root.subviews {
    if let found = hostEditorView(identifier, in: subview) { return found }
  }
  return nil
}
