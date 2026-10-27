import AppKit
import AsterCore
import Testing
@testable import Aster

/// 等后台渲染把结果交回主线程；超时返回 false，由调用方 `#expect` 报告。
@MainActor
private func waitForJSONPane(_ condition: () -> Bool) async -> Bool {
  for _ in 0..<300 {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// 把 JSON 文件 Pane 挂进窗口：撤销栈和工具栏布局都依赖窗口。
@MainActor
private func makeJSONPane(_ text: String) throws
  -> (AppModel, FilePaneViewController, NSWindow, URL, NSSegmentedControl, FilePaneToolbar)
{
  let (model, controller, _, url) = try filePaneTestFixture(text, extension: "json")
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  // 只设 contentViewController 时视图可能保持很小的固有尺寸；显式定尺寸，命中测试才有真实行可点。
  window.setContentSize(NSSize(width: 680, height: 440))
  controller.view.frame = NSRect(x: 0, y: 0, width: 680, height: 440)
  window.orderFront(nil)
  let toolbar = try #require(fileMenuDescendants(controller.view).compactMap { $0 as? FilePaneToolbar }.first)
  let mode = try #require(fileMenuDescendants(toolbar).compactMap { $0 as? NSSegmentedControl }.first)
  return (model, controller, window, url, mode, toolbar)
}

@MainActor
private func selectSegment(_ mode: NSSegmentedControl, _ segment: Int) {
  mode.selectedSegment = segment
  mode.sendAction(mode.action, to: mode.target)
}

@Test("JSON 树视图带 root 行和闭合括号行，默认展开第一层，复制路径与值，编辑后保留展开状态")
@MainActor
func filePaneJSONTreeShowsStructureAndCopies() async throws {
  let (model, controller, window, url, mode, _) = try makeJSONPane(
    #"{"date":"2026-10-24","lead":{"title":"t"},"flashes":[{"score":80}]}"#)
  defer { window.orderOut(nil); model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  selectSegment(mode, 1)
  let tree = try #require(fileMenuDescendants(controller.view).compactMap { $0 as? FileJSONTreeView }.first)
  let outline = tree.outlineView
  #expect(await waitForJSONPane { outline.numberOfRows == 9 })
  func rowTexts() -> [String] {
    (0..<outline.numberOfRows).map {
      (outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? ""
    }
  }
  #expect(rowTexts() == [
    "root : {", #""date" : "2026-10-24""#, #""lead" : {"#, #""title" : "t""#, "}",
    #""flashes" : ["#, "0 : {…}  " + L("1 项"), "]", "}",
  ])
  // 闭合括号行与父行文字左对齐，且不能被选中。
  #expect(outline.frameOfCell(atColumn: 0, row: 4).minX == outline.frameOfCell(atColumn: 0, row: 2).minX)
  #expect(outline.delegate?.outlineView?(outline, shouldSelectItem: outline.item(atRow: 4)!) == false)

  // 行内文字标签不接收鼠标：右键落在文字上时事件交给大纲，菜单才会出现（不只在行的空白处）。
  window.contentView?.layoutSubtreeIfNeeded()
  let titleCell = try #require(outline.view(atColumn: 0, row: 3, makeIfNecessary: true) as? NSTableCellView)
  let label = try #require(titleCell.textField)
  #expect(label is JSONRowLabel)
  #expect(label.hitTest(label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: label.superview)) == nil)
  let pointInWindow = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: nil)
  let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: pointInWindow,
    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
    eventNumber: 0, clickCount: 1, pressure: 1))
  #expect(outline.menu(for: rightClick) === outline.menu)
  #expect(outline.clickedRow == 3)

  outline.selectRowIndexes([3], byExtendingSelection: false)
  outline.copy(nil)
  #expect(NSPasteboard.general.string(forType: .string) == "t")
  let menu = try #require(outline.menu)
  tree.menuNeedsUpdate(menu)
  let copyPath = try #require(menu.items.first { $0.title == L("复制路径") } as? ActionMenuItem)
  _ = copyPath.target?.perform(copyPath.action, with: copyPath)
  #expect(NSPasteboard.general.string(forType: .string) == "$.lead.title")

  // 折叠 lead 后改文档：重渲染沿用折叠状态，flashes 仍展开。
  outline.collapseItem(outline.item(atRow: 2))
  #expect(rowTexts()[2] == #""lead" : {…}  "# + L("1 项"))
  let runtime = try #require(model.selectedTab?.activeRuntime)
  runtime.updateDocument(#"{"date":"2026-10-25","lead":{"title":"t"},"flashes":[{"score":80},{"score":1}]}"#)
  #expect(await waitForJSONPane { outline.numberOfRows == 8 })
  let after = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? JSONTreeItem)?.keyText }
  #expect(after == ["date", "lead", "flashes", "0", "1"])

  // 标题栏按钮：全部折叠只剩 root 行，全部展开显示所有行。
  let buttons = fileMenuDescendants(tree).compactMap { $0 as? NSButton }
  try #require(buttons.first { $0.identifier?.rawValue == "file-pane-json-collapse-all" }).performClick(nil)
  #expect(outline.numberOfRows == 1)
  try #require(buttons.first { $0.identifier?.rawValue == "file-pane-json-expand-all" }).performClick(nil)
  #expect(outline.numberOfRows == 14)
}

@Test("JSON 格式化沿用缩进、可撤销并标记未保存；无效 JSON 不改文本并在树视图报错")
@MainActor
func filePaneJSONFormatIsUndoableAndRejectsInvalid() async throws {
  let original = "{\n    \"a\": 1, \"b\": [true]}"
  let (model, controller, window, url, mode, toolbar) = try makeJSONPane(original)
  defer { window.orderOut(nil); model.tabs.forEach { $0.stop(immediately: true) }; try? FileManager.default.removeItem(at: url) }
  let runtime = try #require(model.selectedTab?.activeRuntime)
  let source = try #require(controller.sourceTextView)
  let format = try #require(fileMenuDescendants(toolbar).compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "file-pane-format" })
  #expect(!format.isHidden)

  format.performClick(nil)
  let formatted = "{\n    \"a\": 1,\n    \"b\": [\n        true\n    ]\n}\n"
  #expect(source.string == formatted)
  #expect(runtime.documentText == formatted)
  #expect(runtime.isDirty)
  source.undoManager?.undo()
  source.didChangeText()
  #expect(source.string == original)

  selectSegment(mode, 1)
  #expect(format.isHidden)
  selectSegment(mode, 0)
  #expect(!format.isHidden)

  let invalid = "{\"a\": }"
  runtime.updateDocument(invalid)
  format.performClick(nil)
  #expect(source.string == invalid)
  #expect(model.notice == JSONParseError(reason: .unexpectedCharacter, line: 1, column: 7).localizedSummary)

  selectSegment(mode, 1)
  let viewSource = fileMenuDescendants(controller.view).compactMap { $0 as? NSButton }
    .first { $0.title == L("查看源码") }
  #expect(await waitForJSONPane { viewSource?.isHiddenOrHasHiddenAncestor == false })
  viewSource?.performClick(nil)
  #expect(mode.selectedSegment == 0)
  #expect(controller.sourceTextView?.isHiddenOrHasHiddenAncestor == false)
}
