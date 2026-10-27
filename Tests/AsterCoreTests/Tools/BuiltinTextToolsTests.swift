// 内置文本工具的行内结果与内容确认：各处理器给出什么结果、什么时候没有结果。
import Foundation
import Testing

@testable import AsterCore

@Suite("BuiltinTextTools")
struct BuiltinTextToolsTests {
  /// 固定偏移的时区，测试不依赖本机时区。
  private func zone(_ seconds: Int) throws -> TimeZone {
    try #require(TimeZone(secondsFromGMT: seconds))
  }

  /// 调用行内结果；`now` 目前未被使用，传固定值即可。
  private func inline(_ handler: ToolBuiltinHandler, _ input: String, in timeZone: TimeZone = .gmt) -> String? {
    BuiltinTextTools.inlineResult(handler, input: input, now: Date(timeIntervalSince1970: 0), timeZone: timeZone)
  }

  // MARK: 行内结果

  /// 时间戳：数字按传入时区显示，日期写法转成秒级时间戳（向下取整）。
  @Test func inlineTimestampConvertsBetweenNumbersAndDates() throws {
    let shanghai = try zone(8 * 3600)
    #expect(inline(.timestamp, "1700000000") == "2023-11-14 22:13:20 +00:00")
    #expect(inline(.timestamp, "1700000000", in: shanghai) == "2023-11-15 06:13:20 +08:00")
    #expect(inline(.timestamp, " 1700000000123\n") == "2023-11-14 22:13:20 +00:00")
    #expect(inline(.timestamp, "2023-11-14 22:13:20") == "1700000000")
    #expect(inline(.timestamp, "2023-11-15 06:13:20", in: shanghai) == "1700000000")
    #expect(inline(.timestamp, "2023-11-15T06:13:20+08:00") == "1700000000")
    #expect(inline(.timestamp, "2023-11-14 22:13:20.999") == "1700000000")
  }

  /// 时间戳：既不是 10/13 位数字也不是合法日期时没有行内结果。
  @Test(arguments: ["hello", "12345", "170000000", "17000000000", "2024-02-30", "2024-13-01"])
  func inlineTimestampIgnoresOtherText(text: String) {
    #expect(inline(.timestamp, text) == nil)
  }

  /// Base64：看起来像 Base64 才给解码文本，普通单词与过短的串不算。
  @Test func inlineBase64DecodesOnlyWhenTextLooksLikeBase64() {
    #expect(inline(.base64, "aGVsbG8gd29ybGQ=") == "hello world")
    #expect(inline(.base64, "\n aGVsbG8gd29ybGQ= \n") == "hello world")
    #expect(inline(.base64, "5L2g5aW95LiW55WM") == "你好世界")
    #expect(inline(.base64, "keyboard") == nil)
    #expect(inline(.base64, "aGk=") == nil)
    #expect(inline(.base64, "hello world") == nil)
  }

  /// URL：含 `%XX` 且解码有变化才给结果；没变化、`+`、非法序列都没有。
  @Test func inlineURLDecodesOnlyWhenTextChanges() {
    #expect(inline(.url, "a%20b%26c") == "a b&c")
    #expect(inline(.url, "%E4%BD%A0%E5%A5%BD") == "你好")
    #expect(inline(.url, " https://example.com/a%2Fb ") == "https://example.com/a/b")
    #expect(inline(.url, "https://example.com/a?b=1") == nil)
    #expect(inline(.url, "a+b") == nil)
    #expect(inline(.url, "100%") == nil)
    #expect(inline(.url, "%zz") == nil)
  }

  /// Hash：对原样输入（不去首尾空白、保留末尾换行）算 SHA-256。
  @Test func inlineHashUsesRawInput() {
    #expect(inline(.hash, "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(inline(.hash, " abc ") == "3eaf1941003943dfaa935adecffcaaa217e290def6fb0181141ced6c9daabaad")
    #expect(inline(.hash, "abc\n") == "edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb")
    #expect(inline(.hash, "你好") == "670d9743542cae3ea7ebe36af56bd53648b0a1126162e78d81a32934a711302e")
  }

  /// JSON、端口、UUID 没有行内结果，即使输入本身合法。
  @Test(arguments: [ToolBuiltinHandler.json, .ports, .uuid], ["{\"a\":1}", ":8080", "1700000000", "abc"])
  func inlineHasNoResultForJSONPortsAndUUID(handler: ToolBuiltinHandler, text: String) {
    #expect(inline(handler, text) == nil)
  }

  /// 空输入和纯空白输入对所有处理器都没有结果（包括 Hash）。
  @Test(arguments: ToolBuiltinHandler.allCases)
  func inlineIgnoresBlankInput(handler: ToolBuiltinHandler) {
    #expect(inline(handler, "") == nil)
    #expect(inline(handler, " \n\t ") == nil)
  }

  // MARK: 内容确认

  /// 内容确认：正则粗筛之后再确认内容真能处理；没有专门判断的处理器一律接受。
  @Test(arguments: [
    (ToolBuiltinHandler.timestamp, "1700000000", true),
    (.timestamp, " 1700000000123\n", true),
    (.timestamp, "2024-01-02", true),
    (.timestamp, "2024年1月2日 03:04", true),
    (.timestamp, "12345", false),
    (.timestamp, "2024-02-30", false),
    (.timestamp, "", false),
    (.base64, "aGVsbG8gd29ybGQ=", true),
    (.base64, "  aGVsbG8gd29ybGQ=\n", true),
    (.base64, "keyboard", false),
    (.base64, "", false),
    (.url, "https://example.com", true),
    (.url, "http://localhost:8080/a", true),
    (.url, "a%20b", true),
    (.url, "plain", false),
    (.url, "%zz", false),
    (.url, "", false),
    (.ports, ":8080", true),
    (.ports, " 443\n", true),
    (.ports, "0", false),
    (.ports, "70000", false),
    (.ports, "abc", false),
    (.ports, "", false),
    (.hash, "anything", true),
    (.hash, "", true),
    (.json, "not json", true),
    (.json, "", true),
    (.uuid, "x", true),
    (.uuid, "", true),
  ])
  func acceptsContentConfirmsCoarseMatches(handler: ToolBuiltinHandler, text: String, expected: Bool) {
    #expect(BuiltinTextTools.acceptsContent(handler, text: text) == expected)
  }
}
