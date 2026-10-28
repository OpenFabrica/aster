// 便笺中心：新建、收起、显示、删除、改颜色与写盘；以及「便笺」工具的内容。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite("StickyNoteCenter")
struct StickyNoteCenterTests {
  /// 每个测试一个临时文件，互不干扰。
  private let fileURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-stickies-\(UUID().uuidString).json")

  /// 用临时文件建一个便笺中心；去抖 10 ms。
  private func makeCenter() -> StickyNoteCenter {
    StickyNoteCenter(store: StickyNoteStore(fileURL: fileURL, saveDelay: .milliseconds(10)))
  }

  /// 读回磁盘上的便笺文件。
  private func readBack() throws -> StickyNoteFile {
    try JSONDecoder().decode(StickyNoteFile.self, from: Data(contentsOf: fileURL))
  }

  /// 新建便笺会开窗口并写盘；改字、换颜色都会保存，颜色同步到窗口纸面。
  @Test func createEditAndRecolorPersist() throws {
    let center = makeCenter()
    defer { center.hideAll() }
    let note = center.createNote(text: "买牛奶", activate: false)
    #expect(center.openNoteIDs == [note.id])
    center.noteTextDidChange(id: note.id, text: "买牛奶\n买面包")
    center.setColor(.blue, id: note.id)
    center.setFloatsOnTop(true, id: note.id)
    center.flush()
    let saved = try #require(try readBack().notes.first)
    #expect(saved.text == "买牛奶\n买面包")
    #expect(saved.color == .blue)
    #expect(saved.floatsOnTop)
    #expect(saved.isOpen)
    #expect(saved.frame != nil)
  }

  /// 关窗口只是收起：内容还在，标成已收起；再显示时重新打开。
  @Test func closingHidesWithoutDeleting() async throws {
    let center = makeCenter()
    defer { center.hideAll() }
    let note = center.createNote(text: "留着", activate: false)
    center.hideAll()
    #expect(center.openNoteIDs.isEmpty)
    #expect(center.note(id: note.id)?.isOpen == false)
    #expect(center.note(id: note.id)?.text == "留着")
    center.show(id: note.id)
    #expect(center.openNoteIDs == [note.id])
    #expect(center.note(id: note.id)?.isOpen == true)
  }

  /// 删除会关窗口并从文件里移除。
  @Test func deleteRemovesNoteAndWindow() throws {
    let center = makeCenter()
    let keep = center.createNote(text: "保留", activate: false)
    let drop = center.createNote(text: "删掉", activate: false)
    center.delete(id: drop.id)
    #expect(center.openNoteIDs == [keep.id])
    center.flush()
    #expect(try readBack().notes.map(\.id) == [keep.id])
    center.hideAll()
  }

  /// 新便笺沿用最近改过的那张的颜色；列表按修改时间倒序。
  @Test func newNotesReuseLatestColorAndSortByModification() {
    let center = makeCenter()
    defer { center.hideAll() }
    let first = center.createNote(activate: false)
    center.setColor(.green, id: first.id)
    let second = center.createNote(activate: false)
    #expect(second.color == .green)
    center.noteTextDidChange(id: first.id, text: "后改的")
    #expect(center.notes.map(\.id) == [first.id, second.id])
  }

  /// 重启后只重新打开上次开着的便笺。
  @Test func restoreReopensOnlyOpenNotes() {
    let center = makeCenter()
    let open = center.createNote(text: "开着", activate: false)
    let hidden = center.createNote(text: "收起", activate: false)
    center.noteWindowDidClose(id: hidden.id)
    center.flush()
    center.hideAll()
    let reloaded = makeCenter()
    defer { reloaded.hideAll() }
    reloaded.restoreOpenNotes()
    #expect(reloaded.openNoteIDs == [open.id])
    #expect(reloaded.notes.count == 2)
  }

  /// 「便笺」工具：没有选中便笺时没有可预填的结果；内容随便笺中心刷新，不会崩溃。
  @Test func stickiesToolContentTracksCenter() {
    let center = makeCenter()
    defer { center.hideAll() }
    let actions = BuiltinToolActions(
      copy: { _ in }, insertIntoTerminal: { _ in }, showNotice: { _, _ in }, heightDidChange: {},
      resultDidChange: {}, window: { nil }, terminalStyle: { ToolTerminalStyle.current() })
    let content = StickiesToolContent(input: ToolInput(text: "牛奶"), actions: actions, center: center)
    center.createNote(text: "买牛奶", activate: false)
    content.update(input: ToolInput(text: "面包"))
    #expect(content.primaryResultText == nil)
    content.teardown()
  }

  /// 带格式的正文、半透明与折叠都会保存；文字和格式都没变时不算修改。
  @Test func richTextAndFlagsPersist() throws {
    let center = makeCenter()
    defer { center.hideAll() }
    let note = center.createNote(text: "粗体", activate: false)
    let bold = NSAttributedString(string: "粗体", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    let rtf = try #require(bold.rtf(from: NSRange(location: 0, length: bold.length), documentAttributes: [:]))
    center.noteTextDidChange(id: note.id, text: "粗体", richText: rtf)
    let modified = try #require(center.note(id: note.id)?.modifiedAt)
    center.noteTextDidChange(id: note.id, text: "粗体", richText: rtf)
    #expect(center.note(id: note.id)?.modifiedAt == modified)
    center.setTranslucent(true, id: note.id)
    center.setCollapsed(true, id: note.id)
    center.flush()
    let saved = try #require(try readBack().notes.first)
    #expect(saved.richText == rtf)
    #expect(saved.isTranslucent)
    #expect(saved.isCollapsed)
  }
}

/// 便笺快捷键与 macOS「便笺」一致；格式操作作用于选区。
@MainActor
@Suite("StickyNoteFormatting")
struct StickyNoteFormattingTests {
  /// 映射一个按键。
  private func command(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> StickyNoteCommand? {
    StickyNoteCommand.command(characters: key, modifiers: modifiers)
  }

  @Test func keysMapToStickiesCommands() {
    #expect(command("n", .command) == .newNote)
    #expect(command("t", .command) == .showFonts)
    #expect(command("b", .command) == .bold)
    #expect(command("i", .command) == .italic)
    #expect(command("u", .command) == .underline)
    #expect(command("=", .command) == .bigger)
    #expect(command("+", [.command, .shift]) == .bigger)
    #expect(command("-", .command) == .smaller)
    #expect(command("1", .command) == .color(.yellow))
    #expect(command("6", .command) == .color(.gray))
    #expect(command("7", .command) == nil)
    #expect(command("f", [.command, .option]) == .floatOnTop)
    #expect(command("t", [.command, .option]) == .translucent)
    // 编辑类快捷键留给正文与菜单。
    #expect(command("c", .command) == nil)
    #expect(command("z", [.command, .shift]) == nil)
    #expect(command("b", []) == nil)
  }

  /// 有选区时粗体整段切换，再按一次去掉；字号在范围内增减。
  @Test func boldTogglesAndSizeAdjustsSelection() throws {
    let textView = NSTextView()
    textView.isRichText = true
    textView.textStorage?.setAttributedString(
      NSAttributedString(string: "hello", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
    textView.setSelectedRange(NSRange(location: 0, length: 5))
    let manager = NSFontManager.shared
    func font() throws -> NSFont {
      try #require(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    }
    StickyNoteFormatter.toggle(.boldFontMask, in: textView)
    #expect(manager.traits(of: try font()).contains(.boldFontMask))
    StickyNoteFormatter.toggle(.boldFontMask, in: textView)
    #expect(!manager.traits(of: try font()).contains(.boldFontMask))
    StickyNoteFormatter.adjustSize(by: 1, in: textView)
    #expect(try font().pointSize == 14)
    StickyNoteFormatter.adjustSize(by: -100, in: textView)
    #expect(try font().pointSize == StickyNoteFormatter.sizeRange.lowerBound)
  }
}
