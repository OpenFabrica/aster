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

@Test("编辑面板：新建、编辑与默认设置和主内容并排，缩窗不遮挡，关闭恢复宽度",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func hostEditorSharesWidthWithBrowser(appearance: NSAppearance.Name) async throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture, appearance: appearance)
  defer { window.orderOut(nil) }
  page.enterGroup("dx-test")
  let browser = page.browserContentView
  let fullWidth = browser.frame.width
  #expect(abs(fullWidth - page.view.bounds.width) < 1)
  let newHost = try #require(hostEditorView("hosts-page-new-host", in: browser) as? NSButton)
  newHost.performClick(nil)

  for (name, mode) in [("new-split", page.editorPanel?.mode), ("edit-split", .edit(fixture.full.id)),
    ("defaults-split", .defaults)]
  {
    page.openEditor(try #require(mode))
    // 等待真实 AppKit 开合动画收尾后再检查最终几何布局。
    try await Task.sleep(for: .milliseconds(250))
    window.contentView?.layoutSubtreeIfNeeded()
    let panel = try #require(page.editorPanel)
    #expect(browser.frame.width < fullWidth)
    #expect(abs(browser.frame.maxX - panel.view.frame.minX) < 1)
    #expect(abs(panel.view.frame.maxX - page.view.bounds.maxX) < 1)
    let search = try #require(hostEditorView("hosts-page-search-bar", in: browser))
    #expect(search.convert(search.bounds, to: page.view).maxX < panel.view.frame.minX)
    let gridFrame = page.hostsGrid.convert(page.hostsGrid.bounds, to: page.view)
    #expect(gridFrame.maxX < panel.view.frame.minX)
    #expect(page.query.group == "dx-test" && page.listing.hosts.count == 2)
    try await captureEditorWindow(window, name: name)
    if panel.mode == .edit(fixture.full.id) {
      let toggle = try #require(hostEditorView("hosts-page-layout-toggle", in: browser) as? NSButton)
      toggle.performClick(nil)
      window.contentView?.layoutSubtreeIfNeeded()
      for card in page.hostsGrid.items {
        #expect(card.convert(card.bounds, to: page.view).maxX < panel.view.frame.minX)
      }
      try await captureEditorWindow(window, name: "edit-list-split")
      toggle.performClick(nil)
    }
  }

  for width in [860.0, 700.0] {
    window.setContentSize(NSSize(width: width, height: 640))
    window.contentView?.layoutSubtreeIfNeeded()
    let panel = try #require(page.editorPanel)
    #expect(abs(browser.frame.maxX - panel.view.frame.minX) < 1)
    #expect(abs(panel.view.frame.maxX - page.view.bounds.maxX) < 1)
    let lastToolbarButton = try #require(hostEditorView("hosts-page-sort", in: browser))
    #expect(lastToolbarButton.convert(lastToolbarButton.bounds, to: page.view).maxX <= panel.view.frame.minX)
    try await captureEditorWindow(window, name: "split-\(Int(width))")
  }

  let panel = try #require(page.editorPanel)
  let cancel = try #require(hostEditorView("host-editor-cancel", in: panel.view) as? NSButton)
  cancel.performClick(nil)
  try await Task.sleep(for: .milliseconds(250))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(page.editorPanel == nil)
  #expect(abs(browser.frame.width - page.view.bounds.width) < 1)
  #expect(window.firstResponder === page.searchField.currentEditor())
  try await captureEditorWindow(window, name: "split-closed")
}
