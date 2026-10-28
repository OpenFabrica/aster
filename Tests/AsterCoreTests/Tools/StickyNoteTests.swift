// 便笺模型：容错解码、编码往返、标题摘要、查询与长度上限。
import Foundation
import Testing

@testable import AsterCore

@Suite("StickyNote")
struct StickyNoteTests {
  /// 从 JSON 文本解码便笺文件。
  private func decode(_ json: String) throws -> StickyNoteFile {
    try JSONDecoder().decode(StickyNoteFile.self, from: Data(json.utf8))
  }

  /// 空对象得到空列表；坏字段用默认值，缺 id 或 id 无效的记录丢弃，重复 id 只留第一条。
  @Test func decodingToleratesCorruptRecords() throws {
    #expect(try decode("{}") == StickyNoteFile())
    let id = UUID()
    let file = try decode(
      """
      {
        "version": 99,
        "notes": [
          {"id": "\(id.uuidString)", "text": "买牛奶", "color": "magenta", "isOpen": "yes",
           "frame": {"x": 10, "y": 20, "width": -5, "height": 100}, "createdAt": 1800000000},
          {"text": "没有 id"},
          {"id": "not-a-uuid"},
          "garbage",
          {"id": "\(id.uuidString)", "text": "重复"}
        ]
      }
      """)
    #expect(file.notes.count == 1)
    let note = try #require(file.notes.first)
    #expect(note.id == id)
    #expect(note.text == "买牛奶")
    #expect(note.color == .yellow)
    #expect(note.isOpen == false)
    #expect(note.frame == nil)
    #expect(note.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(note.modifiedAt == note.createdAt)
  }

  /// 编码后再解码得到同一份数据；时间写成 Unix 秒。
  @Test func encodingRoundTrips() throws {
    let note = StickyNote(
      text: "第一行\n第二行", color: .purple, frame: StickyNoteFrame(x: 1, y: 2, width: 260, height: 240),
      isOpen: true, floatsOnTop: true, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      modifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let data = try JSONEncoder().encode(StickyNoteFile(notes: [note]))
    #expect(try JSONDecoder().decode(StickyNoteFile.self, from: data) == StickyNoteFile(notes: [note]))
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("1700000100"))
    #expect(json.contains("\"version\":1"))
  }

  /// 标题取第一行非空文字并去掉首尾空白；超过 80 个字符截断。
  @Test func titleUsesFirstNonEmptyLine() {
    #expect(StickyNote(text: "\n   \n  待办  \n其它").title == "待办")
    #expect(StickyNote(text: "").title == "")
    let long = String(repeating: "长", count: 100)
    #expect(StickyNote(text: long).title == String(repeating: "长", count: 80) + "…")
  }

  /// 查询忽略大小写与全半角；空查询都命中。
  @Test func matchingIgnoresCaseAndWidth() {
    let note = StickyNote(text: "Deploy ＡＰＩ server")
    #expect(note.matches(""))
    #expect(note.matches("deploy"))
    #expect(note.matches("api"))
    #expect(!note.matches("database"))
  }

  /// 超长文字截到上限，不切开字素簇。
  @Test func textIsClampedWithoutSplittingGraphemes() {
    let emoji = "👩‍👩‍👧"
    let text = String(repeating: "a", count: StickyNote.maximumTextLength - 2) + emoji
    let clamped = StickyNote.clampedText(text)
    #expect(clamped.utf16.count == StickyNote.maximumTextLength - 2)
    #expect(StickyNote.clampedText("short") == "short")
  }
}
