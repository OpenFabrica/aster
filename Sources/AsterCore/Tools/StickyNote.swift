// 便笺（内置工具 `stickies`）的数据模型与 `sticky-notes.json` 的文件格式。不依赖 AppKit；窗口与读写在
// Sources/Aster/Tools/Stickies/。解码是容错的：坏字段用默认值，坏记录逐条丢弃，一张坏便笺不能连累其它便笺。
import Foundation

/// 便笺纸的颜色，与 macOS「便笺」的六种一致。原始值写进文件。
public enum StickyNoteColor: String, CaseIterable, Codable, Sendable {
  case yellow
  case blue
  case green
  case pink
  case purple
  case gray
}

/// 便笺窗口的位置与大小（屏幕坐标，左下角原点，单位点）。
public struct StickyNoteFrame: Equatable, Codable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  /// 逐字段构造。
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// 宽高都是正的有限数才可用；否则按没有位置处理，窗口重新排位。
  public var isUsable: Bool {
    [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
  }
}

/// 一张便笺。
public struct StickyNote: Equatable, Identifiable, Sendable {
  /// 一张便笺最多保存的字符数（UTF-16 计）；粘贴超长内容时截断，防止文件无限变大。
  public static let maximumTextLength = 200_000
  /// 带格式正文（RTF）的字节上限；超过就只存纯文本，格式丢掉，文字不丢。
  public static let maximumRichTextBytes = 4 * 1_048_576

  public var id: UUID
  /// 纯文本正文：标题、搜索与预填都用它。
  public var text: String
  /// 带格式的正文（RTF：字体、字号、粗斜体、下划线、文字颜色）；nil 表示没有格式，按默认字体显示 `text`。
  public var richText: Data?
  public var color: StickyNoteColor
  /// 上次窗口的位置；从没显示过时为 nil。
  public var frame: StickyNoteFrame?
  /// 窗口开着。下次启动 Aster 时重新打开这些便笺。
  public var isOpen: Bool
  /// 浮在其它窗口上面。
  public var floatsOnTop: Bool
  /// 窗口半透明。
  public var isTranslucent: Bool
  /// 折叠成只剩标题栏（`frame` 仍记展开时的大小）。
  public var isCollapsed: Bool
  public var createdAt: Date
  public var modifiedAt: Date

  /// 逐字段构造；`modifiedAt` 缺省等于 `createdAt`。
  public init(
    id: UUID = UUID(),
    text: String = "",
    richText: Data? = nil,
    color: StickyNoteColor = .yellow,
    frame: StickyNoteFrame? = nil,
    isOpen: Bool = true,
    floatsOnTop: Bool = false,
    isTranslucent: Bool = false,
    isCollapsed: Bool = false,
    createdAt: Date = Date(),
    modifiedAt: Date? = nil
  ) {
    self.id = id
    self.text = text
    self.richText = richText.flatMap(Self.acceptedRichText)
    self.color = color
    self.frame = frame
    self.isOpen = isOpen
    self.floatsOnTop = floatsOnTop
    self.isTranslucent = isTranslucent
    self.isCollapsed = isCollapsed
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt ?? createdAt
  }

  /// 列表与窗口标题用的摘要：第一行非空文字，去掉首尾空白，最多 80 个字符；空便笺返回空串。
  public var title: String {
    let line = text.split(whereSeparator: \.isNewline)
      .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return line.count > 80 ? String(line.prefix(80)) + "…" : line
  }

  /// 是否命中查询：忽略大小写、变音与全半角；空查询都命中。
  public func matches(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
  }

  /// 带格式正文在上限内才保留，否则返回 nil（退回纯文本）。
  public static func acceptedRichText(_ data: Data) -> Data? {
    data.isEmpty || data.count > maximumRichTextBytes ? nil : data
  }

  /// 超长文字截到上限（不切开字素簇）。
  public static func clampedText(_ text: String) -> String {
    guard text.utf16.count > maximumTextLength else { return text }
    var result = ""
    var length = 0
    for character in text {
      let next = length + character.utf16.count
      if next > maximumTextLength { break }
      result.append(character)
      length = next
    }
    return result
  }
}

// MARK: - 编解码

extension StickyNote: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, text, richText, color, frame, isOpen, floatsOnTop, isTranslucent, isCollapsed, createdAt, modifiedAt
  }

  /// `id` 必须有效，否则整条丢弃；其余字段坏了用默认值。时间按 Unix 秒读写，不依赖解码器的日期策略。
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    text = Self.clampedText((try? container.decode(String.self, forKey: .text)) ?? "")
    richText = (try? container.decode(Data.self, forKey: .richText)).flatMap(Self.acceptedRichText)
    color = (try? container.decode(StickyNoteColor.self, forKey: .color)) ?? .yellow
    frame = (try? container.decode(StickyNoteFrame.self, forKey: .frame)).flatMap { $0.isUsable ? $0 : nil }
    isOpen = (try? container.decode(Bool.self, forKey: .isOpen)) ?? false
    floatsOnTop = (try? container.decode(Bool.self, forKey: .floatsOnTop)) ?? false
    isTranslucent = (try? container.decode(Bool.self, forKey: .isTranslucent)) ?? false
    isCollapsed = (try? container.decode(Bool.self, forKey: .isCollapsed)) ?? false
    let created = (try? container.decode(Double.self, forKey: .createdAt)).flatMap(Self.date(unixSeconds:))
    let modified = (try? container.decode(Double.self, forKey: .modifiedAt)).flatMap(Self.date(unixSeconds:))
    createdAt = created ?? modified ?? Date(timeIntervalSince1970: 0)
    modifiedAt = modified ?? createdAt
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(richText, forKey: .richText)
    try container.encode(color, forKey: .color)
    try container.encodeIfPresent(frame, forKey: .frame)
    try container.encode(isOpen, forKey: .isOpen)
    try container.encode(floatsOnTop, forKey: .floatsOnTop)
    try container.encode(isTranslucent, forKey: .isTranslucent)
    try container.encode(isCollapsed, forKey: .isCollapsed)
    try container.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    try container.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
  }

  /// 有限的 Unix 秒才转成日期。
  private static func date(unixSeconds: Double) -> Date? {
    unixSeconds.isFinite ? Date(timeIntervalSince1970: unixSeconds) : nil
  }
}

/// `sticky-notes.json` 的整体结构。
public struct StickyNoteFile: Equatable, Sendable {
  public static let currentVersion = 1

  public var notes: [StickyNote]

  /// 逐字段构造。
  public init(notes: [StickyNote] = []) {
    self.notes = notes
  }
}

extension StickyNoteFile: Codable {
  private enum CodingKeys: String, CodingKey {
    case version, notes
  }

  /// 单条记录解不开就跳过；`id` 重复时保留第一条。`version` 只写不校验：字段都是可选的，新版本多出的字段直接忽略。
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let records = (try? container.decode([FailableNote].self, forKey: .notes)) ?? []
    var seen: Set<UUID> = []
    notes = records.compactMap(\.note).filter { seen.insert($0.id).inserted }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentVersion, forKey: .version)
    try container.encode(notes, forKey: .notes)
  }

  /// 解不开的记录变成 nil，而不是让整个数组失败。
  private struct FailableNote: Decodable {
    let note: StickyNote?

    init(from decoder: any Decoder) throws {
      note = try? StickyNote(from: decoder)
    }
  }
}
