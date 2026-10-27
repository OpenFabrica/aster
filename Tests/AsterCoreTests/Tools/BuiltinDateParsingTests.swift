// 内置时间工具：10/13 位时间戳、各种日期写法与时区写法、越界日期，以及时间的展示写法。
import Foundation
import Testing

@testable import AsterCore

@Suite("BuiltinDateParsing")
struct BuiltinDateParsingTests {
  /// 固定偏移的时区，测试不依赖本机时区。
  private func zone(_ seconds: Int = 0) throws -> TimeZone {
    try #require(TimeZone(secondsFromGMT: seconds))
  }

  // MARK: 时间戳

  /// 10 位按秒，13 位按毫秒。
  @Test func parseTimestampReadsSecondsAndMilliseconds() throws {
    let seconds = try #require(BuiltinTextTools.parseTimestamp("1700000000"))
    #expect(seconds == Date(timeIntervalSince1970: 1_700_000_000))
    let milliseconds = try #require(BuiltinTextTools.parseTimestamp("1700000000123"))
    #expect(milliseconds == Date(timeIntervalSince1970: 1_700_000_000.123))
    #expect(BuiltinTextTools.parseTimestamp("0000000000") == Date(timeIntervalSince1970: 0))
    #expect(BuiltinTextTools.parseTimestamp("9999999999999") == Date(timeIntervalSince1970: 9_999_999_999.999))
  }

  /// 只认恰好 10/13 位 ASCII 数字：其它位数、正负号、空白、字母与全角/阿拉伯数字都不行。
  @Test(arguments: [
    "", "1", "170000000", "17000000000", "170000000012", "17000000001234",
    "+700000000", "-700000000", " 1700000000", "1700000000 ", "1700000000\n", "170000000a",
    "1.70000000", "１７００００００００", "١٧٠٠٠٠٠٠٠٠",
  ])
  func parseTimestampRejectsNonTimestampText(text: String) {
    #expect(BuiltinTextTools.parseTimestamp(text) == nil)
  }

  // MARK: 日期写法

  /// 文档里列出的各种写法（没写时区时按 UTC 理解），结果是 UTC 秒数。
  @Test(arguments: [
    ("2024-01-02", 1_704_153_600.0),
    ("2024-01-02 03:04", 1_704_164_640),
    ("2024-01-02 03:04:05", 1_704_164_645),
    ("2024-01-02T03:04:05", 1_704_164_645),
    ("2024-01-02t03:04:05", 1_704_164_645),
    ("2024-01-02 T03:04:05", 1_704_164_645),
    ("2024-01-02 00:00", 1_704_153_600),
    ("2024-01-02 23:59:59", 1_704_239_999),
    ("  2024-01-02 03:04:05  \n", 1_704_164_645),
    ("2024-01-02 03:04:05.123", 1_704_164_645.123),
    ("2024-01-02 03:04:05,5", 1_704_164_645.5),
    ("2024-01-02T03:04:05.123456789Z", 1_704_164_645.123456789),
    // 日期分隔符可以是 - / .，月日可以是一位，时可以是一位。
    ("2024/01/02 03:04:05", 1_704_164_645),
    ("2024.01.02 03:04:05", 1_704_164_645),
    ("2024/1/2 3:04:05", 1_704_164_645),
    ("2024-1-2", 1_704_153_600),
    // 中文写法。
    ("2024年1月2日", 1_704_153_600),
    ("2024年01月02日 03:04", 1_704_164_640),
    ("2024年1月2日 03:04:05", 1_704_164_645),
    ("2024年1月2日 03:04:05 +08:00", 1_704_135_845),
    // 闰年的 2 月 29 日。
    ("2024-02-29", 1_709_164_800),
    ("2000-02-29", 951_782_400),
  ])
  func parseDateReadsDocumentedForms(text: String, expected: Double) throws {
    let date = try #require(BuiltinTextTools.parseDate(text, timeZone: zone()))
    #expect(abs(date.timeIntervalSince1970 - expected) < 1e-5, "\(text)")
  }

  /// 时区写法：`Z`、`UTC`、`GMT`、`±HH:MM`、`±HHMM`、`±HH`，可紧跟也可隔一个空格；文本里的时区优先于传入的时区。
  @Test(arguments: [
    ("2024-01-02T03:04:05Z", 1_704_164_645.0),
    ("2024-01-02T03:04:05z", 1_704_164_645),
    ("2024-01-02 03:04:05 UTC", 1_704_164_645),
    ("2024-01-02 03:04:05UTC", 1_704_164_645),
    ("2024-01-02 03:04:05 GMT", 1_704_164_645),
    ("2024-01-02T03:04:05+00:00", 1_704_164_645),
    ("2024-01-02T03:04:05+08:00", 1_704_135_845),
    ("2024-01-02T03:04:05+0800", 1_704_135_845),
    ("2024-01-02T03:04:05+08", 1_704_135_845),
    ("2024-01-02 03:04:05 +08:00", 1_704_135_845),
    ("2024-01-02 03:04:05+08:00", 1_704_135_845),
    ("2024-01-02T03:04:05-05:00", 1_704_182_645),
    ("2024-01-02T03:04:05-0500", 1_704_182_645),
    ("2024-01-02T03:04:05+05:30", 1_704_144_845),
    ("2024-01-02 03:04:05.5 +08:00", 1_704_135_845.5),
  ])
  func parseDateReadsTimeZoneSuffixes(text: String, expected: Double) throws {
    // 传入 -03:00 以证明文本里的时区覆盖了它。
    let date = try #require(BuiltinTextTools.parseDate(text, timeZone: zone(-3 * 3600)))
    #expect(abs(date.timeIntervalSince1970 - expected) < 1e-5, "\(text)")
  }

  /// 没写时区时按传入的时区理解；只有日期时是那个时区的零点。
  @Test func parseDateUsesGivenZoneWhenTextHasNone() throws {
    let shanghai = try zone(8 * 3600)
    let newYork = try zone(-5 * 3600)
    #expect(BuiltinTextTools.parseDate("2024-01-02 03:04:05", timeZone: shanghai)?.timeIntervalSince1970 == 1_704_135_845)
    #expect(BuiltinTextTools.parseDate("2024-01-02 03:04:05", timeZone: newYork)?.timeIntervalSince1970 == 1_704_182_645)
    #expect(BuiltinTextTools.parseDate("2024-01-02", timeZone: shanghai)?.timeIntervalSince1970 == 1_704_124_800)
    #expect(BuiltinTextTools.parseDate("2024年1月2日", timeZone: shanghai)?.timeIntervalSince1970 == 1_704_124_800)
  }

  /// 越界或不合法的日期时间返回 nil：月日越界、非闰年 2 月 29 日、25 点、60 秒、时区越界、多余尾巴、年份位数不对。
  @Test(arguments: [
    "", "   ", "hello", "2024", "2024-01", "2024-01-", "24-01-02", "20240-01-02", "0000-01-02", "２０２４-01-02",
    "2024-13-01", "2024-00-10", "2024-01-00", "2024-01-32",
    "2023-02-29", "2024-02-30", "1900-02-29", "2100-02-29", "2024-04-31", "2024-06-31", "2024-09-31", "2024-11-31",
    "2024-01-02 24:00", "2024-01-02 25:00", "2024-01-02 23:60", "2024-01-02 23:59:60",
    "2024-01-02 03", "2024-01-02 03:4", "2024-01-02T", "2024-01-02 03:04:", "2024-01-02 03:04:5",
    "2024-01-02 03:04:05.", "2024-01-02 03:04:05.1234567890",
    "2024-01-02T03:04:05+24:00", "2024-01-02T03:04:05+08:60", "2024-01-02T03:04:05+8",
    "2024-01-02T03:04:05+08:0", "2024-01-02T03:04:05+", "2024-01-02T03:04:05+0", "2024-01-02T03:04:05+080",
    "2024-01-02 foo", "2024-01-02x", "2024-01-02 03:04:05 +08:00 extra", "2024-01-02T03:04:05ZZ",
    "2024-01/02", "2024/01-02", "2024-001-02", "2024-1-002",
    "2024年1月2", "2024年1月", "2024年13月1日", "2024年2月30日", "2024年1月2日T03:04", "2024年1月2号",
  ])
  func parseDateRejectsInvalidText(text: String) throws {
    let utc = try zone()
    #expect(BuiltinTextTools.parseDate(text, timeZone: utc) == nil, "\(text)")
  }

  /// 每个月的天数，含世纪年规则：能被 4 整除且不能被 100 整除，或能被 400 整除才是闰年。
  @Test(arguments: [
    (1, 2023, 31), (2, 2023, 28), (3, 2023, 31), (4, 2023, 30), (5, 2023, 31), (6, 2023, 30),
    (7, 2023, 31), (8, 2023, 31), (9, 2023, 30), (10, 2023, 31), (11, 2023, 30), (12, 2023, 31),
    (2, 2024, 29), (2, 1900, 28), (2, 2000, 29), (2, 2100, 28), (2, 2400, 29),
  ])
  func daysInMonthFollowsGregorianRules(month: Int, year: Int, expected: Int) {
    #expect(BuiltinTextTools.daysInMonth(month, year: year) == expected)
  }

  // MARK: 展示

  /// `yyyy-MM-dd HH:mm:ss ±HH:mm`：数字固定为 ASCII，偏移按传入时区。
  @Test func formatDateUsesFixedLayoutInGivenZone() throws {
    let utc = try zone()
    let shanghai = try zone(8 * 3600)
    let minus530 = try zone(-(5 * 3600 + 1800))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(BuiltinTextTools.formatDate(date, timeZone: utc) == "2023-11-14 22:13:20 +00:00")
    #expect(BuiltinTextTools.formatDate(date, timeZone: shanghai) == "2023-11-15 06:13:20 +08:00")
    #expect(BuiltinTextTools.formatDate(date, timeZone: minus530) == "2023-11-14 16:43:20 -05:30")
    #expect(BuiltinTextTools.formatDate(Date(timeIntervalSince1970: 0), timeZone: utc) == "1970-01-01 00:00:00 +00:00")
    #expect(BuiltinTextTools.formatDate(Date(timeIntervalSince1970: -86_400), timeZone: utc) == "1969-12-31 00:00:00 +00:00")
  }

  /// 秒级时间戳向下取整，早于 1970 年时也是向负方向取整。
  @Test(arguments: [(1_700_000_000.0, "1700000000"), (1_700_000_000.9, "1700000000"), (0.0, "0"), (-0.5, "-1"), (-1.0, "-1")])
  func unixSecondsRoundsDown(interval: Double, expected: String) {
    #expect(BuiltinTextTools.unixSeconds(Date(timeIntervalSince1970: interval)) == expected)
  }

  /// 时间的五种写法：本地时间、UTC、秒、毫秒、ISO 8601；秒和毫秒向下取整。
  @Test func describeTimestampListsFiveRepresentations() throws {
    // .5 秒在二进制浮点里精确可表示，毫秒数不会因舍入误差少 1。
    let date = Date(timeIntervalSince1970: 1_700_000_000.5)
    let lines = BuiltinTextTools.describeTimestamp(date, timeZone: try zone(8 * 3600))
    #expect(lines.count == 5)
    #expect(
      lines.map(\.value) == [
        "2023-11-15 06:13:20 +08:00", "2023-11-14 22:13:20 +00:00", "1700000000", "1700000000500", "2023-11-14T22:13:20Z",
      ])
    #expect(lines[0].label == L("本地时间"))
    #expect(lines[1].label == "UTC")
    #expect(lines[2].label == L("秒"))
    #expect(lines[3].label == L("毫秒"))
    #expect(lines[4].label == "ISO 8601")
  }

  /// 早于 1970 年：毫秒向下取整（-0.5 秒是 -500 毫秒、-1 秒），本地时间与 UTC 相同时两行一致。
  @Test func describeTimestampHandlesTimesBeforeEpoch() throws {
    let lines = BuiltinTextTools.describeTimestamp(Date(timeIntervalSince1970: -0.5), timeZone: try zone())
    #expect(lines[0].value == lines[1].value)
    #expect(lines[0].value == "1969-12-31 23:59:59 +00:00")
    #expect(lines[2].value == "-1")
    #expect(lines[3].value == "-500")
    #expect(lines[4].value == "1969-12-31T23:59:59Z")
  }

  /// 展示出来的本地时间能被 `parseDate` 原样读回（整秒），不论时区。
  @Test(arguments: [0, 8 * 3600, -(5 * 3600 + 1800)])
  func formattedDateParsesBack(offset: Int) throws {
    let timeZone = try zone(offset)
    let utc = try zone()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let text = BuiltinTextTools.formatDate(date, timeZone: timeZone)
    #expect(BuiltinTextTools.parseDate(text, timeZone: utc) == date)
    let iso = try #require(BuiltinTextTools.describeTimestamp(date, timeZone: timeZone).last)
    #expect(BuiltinTextTools.parseDate(iso.value, timeZone: utc) == date)
  }
}
