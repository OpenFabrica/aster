// 内置原生工具的纯逻辑：日期解析、URL 拆分与默认模式、端口过滤、Base64 默认方向、随机串长度。
import AsterCore
import Foundation
import Testing

@testable import Aster

struct BuiltinNativeParsingTests {
  /// 2024-01-01 12:00:00 UTC。
  private let noon = Date(timeIntervalSince1970: 1_704_110_400)

  // MARK: 日期

  @Test func dateParserReadsCommonFormats() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(BuiltinDateParser.parse("2024-01-01 12:00:00", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024/01/01 12:00:00", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024-01-01T12:00:00Z", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024-01-01T12:00:00.000Z", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024-01-01T20:00:00+08:00", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024-01-01T20:00:00+0800", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024-01-01T12:00:00", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("  2024-01-01 12:00  ", timeZone: utc) == noon)
    #expect(BuiltinDateParser.parse("2024-01-01", timeZone: utc) == Date(timeIntervalSince1970: 1_704_067_200))
  }

  @Test func dateParserUsesGivenTimeZoneForZonelessDates() throws {
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    #expect(BuiltinDateParser.parse("2024-01-01 20:00:00", timeZone: shanghai) == noon)
  }

  @Test func dateParserRoundTripsTimestampToolOutput() throws {
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let utc = try #require(TimeZone(identifier: "UTC"))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let text = BuiltinTextTools.formatDate(date, timeZone: shanghai)
    #expect(BuiltinDateParser.parse(text, timeZone: utc) == date)
  }

  @Test func dateParserRejectsGarbage() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(BuiltinDateParser.parse("", timeZone: utc) == nil)
    #expect(BuiltinDateParser.parse("hello", timeZone: utc) == nil)
    #expect(BuiltinDateParser.parse("2024-13-45", timeZone: utc) == nil)
    #expect(BuiltinDateParser.parse("2024-01-01 12:00:00 extra", timeZone: utc) == nil)
  }

  // MARK: URL

  @Test func urlPartsSplitsQueryAndDecodesValues() throws {
    let parts = try #require(
      BuiltinURLParts.parse("https://example.com:8443/a%20b/c?q=hello+world&x=%2B1&empty&n=%E4%B8%AD#frag%20ment"))
    #expect(parts.scheme == "https")
    #expect(parts.host == "example.com")
    #expect(parts.port == 8443)
    #expect(parts.path == "/a b/c")
    #expect(parts.fragment == "frag ment")
    #expect(
      parts.parameters == [
        ToolResultLine(label: "q", value: "hello world"),
        ToolResultLine(label: "x", value: "+1"),
        ToolResultLine(label: "empty", value: ""),
        ToolResultLine(label: "n", value: "中"),
      ])
    #expect(parts.parametersText == "q=hello world\nx=+1\nempty=\nn=中")
    #expect(parts.lines.first == ToolResultLine(label: L("协议"), value: "https"))
  }

  @Test func urlPartsAcceptsBareQueryStrings() throws {
    let bare = try #require(BuiltinURLParts.parse("a=1&b=two%20words"))
    #expect(bare.scheme == nil)
    #expect(bare.parameters == [ToolResultLine(label: "a", value: "1"), ToolResultLine(label: "b", value: "two words")])
    let leading = try #require(BuiltinURLParts.parse("?a=1"))
    #expect(leading.parameters == [ToolResultLine(label: "a", value: "1")])
  }

  @Test func urlPartsKeepsNonASCIIURLsReadable() throws {
    let parts = try #require(BuiltinURLParts.parse("https://example.com/路径?q=中文&w=a b"))
    #expect(parts.scheme == "https")
    #expect(parts.parameters == [ToolResultLine(label: "q", value: "中文"), ToolResultLine(label: "w", value: "a b")])
  }

  @Test func urlPartsRejectsPlainText() {
    #expect(BuiltinURLParts.parse("") == nil)
    #expect(BuiltinURLParts.parse("hello world") == nil)
    #expect(BuiltinURLParts.parse("example.com/path") == nil)
  }

  @Test func urlModePrefersDecodeThenSplitThenEncode() {
    #expect(BuiltinURLMode.preferred(for: "a%20b") == .decode)
    #expect(BuiltinURLMode.preferred(for: "https://x.com/s?q=%E4%B8%AD") == .decode)
    #expect(BuiltinURLMode.preferred(for: "https://x.com/s?q=1") == .split)
    #expect(BuiltinURLMode.preferred(for: "HTTP://X.COM/?a") == .split)
    #expect(BuiltinURLMode.preferred(for: "https://x.com/path") == .encode)
    #expect(BuiltinURLMode.preferred(for: "hello world") == .encode)
  }

  // MARK: 端口

  @Test func portFilterParsesPortQueries() {
    #expect(BuiltinPortFilter.port(from: "3000") == 3000)
    #expect(BuiltinPortFilter.port(from: ":8080") == 8080)
    #expect(BuiltinPortFilter.port(from: " 22 ") == 22)
    #expect(BuiltinPortFilter.port(from: "0") == nil)
    #expect(BuiltinPortFilter.port(from: "65536") == nil)
    #expect(BuiltinPortFilter.port(from: "ports") == nil)
    #expect(BuiltinPortFilter.port(from: "１２３") == nil)
    #expect(BuiltinPortFilter.port(from: nil) == nil)
  }

  @Test func portFilterMatchesExactPortAndSortsByPort() {
    let ports = [
      ListeningPort(processIdentifier: 3, endpoint: "*:30000"),
      ListeningPort(processIdentifier: 2, endpoint: "[::1]:3000"),
      ListeningPort(processIdentifier: 1, endpoint: "127.0.0.1:3000"),
      ListeningPort(processIdentifier: 4, endpoint: "*:22"),
    ]
    #expect(BuiltinPortFilter.filtered(ports, port: 3000).map(\.endpoint) == ["127.0.0.1:3000", "[::1]:3000"])
    #expect(
      BuiltinPortFilter.filtered(ports, port: nil).map(\.endpoint)
        == ["*:22", "127.0.0.1:3000", "[::1]:3000", "*:30000"])
    #expect(BuiltinPortFilter.filtered(ports, port: 80).isEmpty)
  }

  // MARK: Base64 与随机串

  @Test func base64DecodesWrappedTextAndPicksDirection() {
    #expect(BuiltinBase64.decode("aGVs\nbG8g\nd29y\nbGQ=") == "hello world")
    #expect(BuiltinBase64.decode("aGVsbG8") == "hello")
    #expect(BuiltinBase64.decode("   ") == nil)
    #expect(BuiltinBase64.prefersDecoding("aGVsbG8gd29ybGQ="))
    #expect(!BuiltinBase64.prefersDecoding("hello world"))
    #expect(!BuiltinBase64.prefersDecoding("AAAA"))
    #expect(!BuiltinBase64.prefersDecoding(""))
  }

  @Test func randomLengthAcceptsOnlyOneTo4096() {
    #expect(BuiltinRandomLength.parse("32") == 32)
    #expect(BuiltinRandomLength.parse(" 1 ") == 1)
    #expect(BuiltinRandomLength.parse("4096") == 4096)
    #expect(BuiltinRandomLength.parse("0") == nil)
    #expect(BuiltinRandomLength.parse("4097") == nil)
    #expect(BuiltinRandomLength.parse("abc") == nil)
  }
}
