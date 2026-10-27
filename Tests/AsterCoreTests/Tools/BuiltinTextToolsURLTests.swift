// 内置文本工具的 URL 与端口：百分号编码、http(s) 判断、拆分 URL 或查询串、端口号解析。
import Foundation
import Testing

@testable import AsterCore

@Suite("BuiltinTextToolsURL")
struct BuiltinTextToolsURLTests {
  // MARK: 编码与解码

  /// 编码只放过 `A–Z a–z 0–9 - . _ ~`，其余字节（包括空格、`+`、汉字）都按 UTF-8 编码。
  @Test(arguments: [
    ("", ""),
    ("AZaz09-._~", "AZaz09-._~"),
    ("a b", "a%20b"),
    ("a+b&c=d/e?f#g", "a%2Bb%26c%3Dd%2Fe%3Ff%23g"),
    ("100%", "100%25"),
    ("é", "%C3%A9"),
    ("你好", "%E4%BD%A0%E5%A5%BD"),
    ("😀", "%F0%9F%98%80"),
  ])
  func encodeKeepsOnlyUnreservedCharacters(text: String, expected: String) {
    #expect(BuiltinTextTools.urlEncode(text) == expected)
  }

  /// 解码还原百分号序列；`+` 保持原样；序列不合法或解出来不是 UTF-8 时为 nil。
  @Test(arguments: [
    ("a%20b", "a b"),
    ("%E4%BD%A0", "你"),
    ("a+b", "a+b"),
    ("%2b", "+"),
    ("plain", "plain"),
    ("", ""),
    ("%zz", nil),
    ("%", nil),
    ("%2", nil),
    ("%E4%BD", nil),
  ] as [(String, String?)])
  func decodeRestoresPercentSequences(text: String, expected: String?) {
    #expect(BuiltinTextTools.urlDecode(text) == expected)
  }

  /// 编码再解码得到原文。
  @Test(arguments: ["a b&c=d", "你好，世界 🧰", "50% off + more", "~._-"])
  func encodeThenDecodeRoundTrips(text: String) {
    #expect(BuiltinTextTools.urlDecode(BuiltinTextTools.urlEncode(text)) == text)
  }

  // MARK: http(s) 判断

  /// 协议是 http/https（不分大小写）、有主机、不含空白才算 http(s) 地址。
  @Test(arguments: [
    ("http://example.com", true),
    ("https://example.com/path?q=1#frag", true),
    ("HTTPS://EXAMPLE.COM", true),
    ("http://localhost:8080", true),
    ("http://127.0.0.1/a", true),
    ("ftp://example.com", false),
    ("mailto:a@example.com", false),
    ("example.com", false),
    ("//example.com", false),
    ("https://", false),
    ("http://", false),
    ("https:///path", false),
    ("https://example.com/a b", false),
    (" https://example.com", false),
    ("https://example.com\n", false),
    ("", false),
  ])
  func isHTTPURLRequiresSchemeHostAndNoWhitespace(text: String, expected: Bool) {
    #expect(BuiltinTextTools.isHTTPURL(text) == expected)
  }

  // MARK: 拆分

  /// 完整 URL：协议、主机、端口、路径、每个查询参数（解码，`+` 当空格）、片段，按这个顺序。
  @Test func urlComponentsSplitsFullURL() throws {
    let lines = try #require(
      BuiltinTextTools.urlComponents("https://example.com:8443/a/b?x=1&y=hello+world&z=%E4%BD%A0&x=2#frag"))
    #expect(
      lines == [
        ToolResultLine(label: L("协议"), value: "https"),
        ToolResultLine(label: L("主机"), value: "example.com"),
        ToolResultLine(label: L("端口号"), value: "8443"),
        ToolResultLine(label: L("路径"), value: "/a/b"),
        ToolResultLine(label: "x", value: "1"),
        ToolResultLine(label: "y", value: "hello world"),
        ToolResultLine(label: "z", value: "你"),
        ToolResultLine(label: "x", value: "2"),
        ToolResultLine(label: L("片段标识"), value: "frag"),
      ])
  }

  /// 没有端口、路径、查询、片段的部分不出行；首尾空白先去掉；空片段也不出行。
  @Test func urlComponentsOmitsMissingParts() throws {
    let bare = try #require(BuiltinTextTools.urlComponents("  http://example.com \n"))
    #expect(bare.map(\.value) == ["http", "example.com"])
    let emptyFragment = try #require(BuiltinTextTools.urlComponents("http://example.com/#"))
    #expect(emptyFragment.map(\.value) == ["http", "example.com", "/"])
  }

  /// 查询参数按表单规则解码：`%2B` 是加号、`+` 是空格；没有值的参数值为空。
  @Test func urlComponentsDecodesQueryLikeAForm() throws {
    let lines = try #require(BuiltinTextTools.urlComponents("https://example.com/?a%20b=c%26d&p=a%2Bb&q=a+b&flag&e="))
    #expect(
      Array(lines.dropFirst(2)) == [
        ToolResultLine(label: L("路径"), value: "/"),
        ToolResultLine(label: "a b", value: "c&d"),
        ToolResultLine(label: "p", value: "a+b"),
        ToolResultLine(label: "q", value: "a b"),
        ToolResultLine(label: "flag", value: ""),
        ToolResultLine(label: "e", value: ""),
      ])
  }

  /// 坏的百分号序列显示原文，不让一个坏参数吞掉整行：完整 URL 里只有一个坏参数，或查询串里好坏参数混在一起。
  @Test func urlComponentsShowsBadPercentSequenceVerbatim() throws {
    let single = try #require(BuiltinTextTools.urlComponents("https://example.com/?bad=%zz"))
    #expect(single.last == ToolResultLine(label: "bad", value: "%zz"))
    let trailing = try #require(BuiltinTextTools.urlComponents("https://example.com/?bad=100%"))
    #expect(trailing.last == ToolResultLine(label: "bad", value: "100%"))
    let mixed = try #require(BuiltinTextTools.urlComponents("a%20b=c&bad=%zz&p=a%2Bb"))
    #expect(
      mixed == [
        ToolResultLine(label: "a b", value: "c"),
        ToolResultLine(label: "bad", value: "%zz"),
        ToolResultLine(label: "p", value: "a+b"),
      ])
  }

  /// 完整 URL 的查询里有坏参数时，其余好参数仍应正常解码。
  @Test func urlComponentsKeepsGoodParametersDecodedBesideABadOne() throws {
    let lines = try #require(BuiltinTextTools.urlComponents("https://example.com/?a%20b=c&bad=%zz"))
    #expect(
      Array(lines.dropFirst(3)) == [
        ToolResultLine(label: "a b", value: "c"),
        ToolResultLine(label: "bad", value: "%zz"),
      ])
  }

  /// 只有查询串也能拆（可带前导 `?`、首尾空白）；值里的 `=` 保留。
  @Test(arguments: ["a=1&b=hello+world&c=a=b", "?a=1&b=hello+world&c=a=b", " a=1&b=hello+world&c=a=b\n"])
  func urlComponentsSplitsBareQueryString(text: String) throws {
    let lines = try #require(BuiltinTextTools.urlComponents(text))
    #expect(
      lines == [
        ToolResultLine(label: "a", value: "1"),
        ToolResultLine(label: "b", value: "hello world"),
        ToolResultLine(label: "c", value: "a=b"),
      ])
  }

  /// 表单解码：`+` 先变空格再做百分号解码，序列不合法时保留变空格后的原文；空查询没有参数行，空段被跳过。
  @Test func formDecodeAndQueryLinesHandleEdgeCases() {
    #expect(BuiltinTextTools.formDecode("a+b%20c%2B") == "a b c+")
    #expect(BuiltinTextTools.formDecode("%zz+x") == "%zz x")
    #expect(BuiltinTextTools.queryLines(nil).isEmpty)
    #expect(BuiltinTextTools.queryLines("").isEmpty)
    #expect(BuiltinTextTools.queryLines("a=1&&b=2&").map(\.label) == ["a", "b"])
  }

  /// 既不是 URL 也不是查询串（没有 `=`、含内部空白、空串、没有主机的协议、不带协议的地址）时为 nil。
  @Test(arguments: [
    "", "   ", "hello", "?", "a b=c", "https://example.com/a b", "mailto:a@example.com", "no equals here",
    "localhost:8080/path?x=1", "example.com/a?b=c",
  ])
  func urlComponentsRejectsOtherText(text: String) {
    #expect(BuiltinTextTools.urlComponents(text) == nil)
  }

  // MARK: 端口

  /// 端口：可带前导冒号与首尾空白，1–65535，只认 ASCII 数字，最多 5 位。
  @Test(arguments: [
    ("8080", 8080),
    (":8080", 8080),
    ("  :443 \n", 443),
    ("1", 1),
    ("65535", 65535),
    ("00080", 80),
    ("65536", nil),
    ("99999", nil),
    ("0", nil),
    ("00000", nil),
    ("000080", nil),
    ("", nil),
    (":", nil),
    ("::80", nil),
    ("80a", nil),
    ("8 0", nil),
    ("+80", nil),
    ("-80", nil),
    ("٨٠", nil),
    ("８０８０", nil),
  ] as [(String, Int?)])
  func portParsesAsciiDigitsInRange(text: String, expected: Int?) {
    #expect(BuiltinTextTools.port(text) == expected)
  }
}
