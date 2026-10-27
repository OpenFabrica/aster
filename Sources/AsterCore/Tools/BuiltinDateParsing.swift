// 时间戳与日期：10/13 位时间戳、常见日期写法的解析，以及时间的几种展示写法。
import Foundation

extension BuiltinTextTools {
  /// 10 位按秒、13 位按毫秒解析；只接受 ASCII 数字（不接受正负号、空白与全角数字）。
  public static func parseTimestamp(_ text: String) -> Date? {
    let scalars = text.unicodeScalars
    guard scalars.count == 10 || scalars.count == 13, scalars.allSatisfy(ToolTextRules.isDigit),
      let value = Int64(text)
    else { return nil }
    return scalars.count == 10
      ? Date(timeIntervalSince1970: TimeInterval(value))
      : Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
  }

  /// 解析常见日期写法；没写时区时按 `timeZone` 理解。支持：
  /// `2024-01-02`、`2024-01-02 03:04`、`2024-01-02 03:04:05.123`、`2024-01-02T03:04:05Z`、
  /// `2024-01-02T03:04:05+08:00`（也可 `+0800`、`+08`、` UTC`、` GMT`、空格后再写时区），
  /// 日期用 `-`、`/` 或 `.` 分隔，以及 `2024年1月2日 03:04:05`。日期或时间越界（如 2 月 30 日、25 点）返回 nil。
  public static func parseDate(_ text: String, timeZone: TimeZone) -> Date? {
    var scanner = DateScanner(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let year = scanner.number(digits: 4...4), year >= 1 else { return nil }
    let month: Int
    let day: Int
    let chinese = scanner.consume("年")
    if chinese {
      guard let parsedMonth = scanner.number(digits: 1...2), scanner.consume("月"),
        let parsedDay = scanner.number(digits: 1...2), scanner.consume("日")
      else { return nil }
      (month, day) = (parsedMonth, parsedDay)
    } else {
      guard let separator = scanner.consumeAny(of: ["-", "/", "."]), let parsedMonth = scanner.number(digits: 1...2),
        scanner.consume(separator), let parsedDay = scanner.number(digits: 1...2)
      else { return nil }
      (month, day) = (parsedMonth, parsedDay)
    }
    guard (1...12).contains(month), (1...daysInMonth(month, year: year)).contains(day) else { return nil }
    guard let time = scanner.time(allowsT: !chinese), let zone = scanner.zone(default: timeZone) else { return nil }
    scanner.skipSpaces()
    guard scanner.isAtEnd else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(
      from: DateComponents(
        year: year, month: month, day: day, hour: time.hour, minute: time.minute, second: time.second,
        nanosecond: time.nanosecond))
  }

  /// `yyyy-MM-dd HH:mm:ss ±HH:mm`。
  public static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
    return formatter.string(from: date)
  }

  /// 时间的多种写法：本地时间、UTC、秒、毫秒、ISO 8601。
  public static func describeTimestamp(_ date: Date, timeZone: TimeZone) -> [ToolResultLine] {
    let utc = TimeZone(secondsFromGMT: 0) ?? timeZone
    return [
      ToolResultLine(label: L("本地时间"), value: formatDate(date, timeZone: timeZone)),
      ToolResultLine(label: "UTC", value: formatDate(date, timeZone: utc)),
      ToolResultLine(label: L("秒"), value: unixSeconds(date)),
      ToolResultLine(label: L("毫秒"), value: String(Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)))),
      ToolResultLine(label: "ISO 8601", value: date.formatted(.iso8601)),
    ]
  }

  /// 秒级 Unix 时间戳（向下取整）。
  static func unixSeconds(_ date: Date) -> String {
    String(Int64(date.timeIntervalSince1970.rounded(.down)))
  }

  /// 公历某月的天数。
  static func daysInMonth(_ month: Int, year: Int) -> Int {
    switch month {
    case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }
}

/// 日期文本的逐字符扫描器，只认 ASCII 数字。
private struct DateScanner {
  /// 一天中的时刻。
  struct Time {
    var hour = 0
    var minute = 0
    var second = 0
    var nanosecond = 0
  }

  private let scalars: [Unicode.Scalar]
  private var index = 0

  /// 从去掉首尾空白的文本开始扫描。
  init(_ text: String) {
    scalars = Array(text.unicodeScalars)
  }

  var isAtEnd: Bool { index >= scalars.count }

  /// 读取一整段连续数字，位数必须在范围内（整段超长也算不合法，例如 `2024-001-02`）；不合法时不前进。
  mutating func number(digits: ClosedRange<Int>) -> Int? {
    var end = index
    while end < scalars.count, ToolTextRules.isDigit(scalars[end]) { end += 1 }
    guard digits.contains(end - index) else { return nil }
    return take(end - index)
  }

  /// 恰好读取 `count` 个数字，不管后面是否还有数字（时区 `+0800` 需要两位两位地读）。
  mutating func fixed(count: Int) -> Int? {
    guard index + count <= scalars.count, scalars[index..<(index + count)].allSatisfy(ToolTextRules.isDigit) else {
      return nil
    }
    return take(count)
  }

  /// 小数部分：1–9 位，换算成纳秒。
  mutating func fraction() -> Int? {
    let start = index
    guard let value = number(digits: 1...9) else { return nil }
    let count = index - start
    return value * (0..<(9 - count)).reduce(1) { product, _ in product * 10 }
  }

  /// 消费 `count` 个已确认是数字的标量并转成整数。
  private mutating func take(_ count: Int) -> Int? {
    let value = Int(String(String.UnicodeScalarView(scalars[index..<(index + count)])))
    index += count
    return value
  }

  /// 下一段文本等于 `text` 时消费它。
  mutating func consume(_ text: String) -> Bool {
    let expected = Array(text.unicodeScalars)
    guard index + expected.count <= scalars.count, Array(scalars[index..<(index + expected.count)]) == expected else {
      return false
    }
    index += expected.count
    return true
  }

  /// 消费候选之一并返回它。
  mutating func consumeAny(of candidates: [String]) -> String? {
    candidates.first { consume($0) }
  }

  /// 跳过空格。
  mutating func skipSpaces() {
    while index < scalars.count, scalars[index] == " " { index += 1 }
  }

  /// 可选的时刻：`T` 或空格之后的 `H:mm[:ss[.fraction]]`；没有时刻时返回零点。格式不完整时返回 nil。
  mutating func time(allowsT: Bool) -> Time? {
    let start = index
    skipSpaces()
    let hasT = allowsT && (consume("T") || consume("t"))
    guard hasT || (index < scalars.count && ToolTextRules.isDigit(scalars[index])) else {
      index = start
      return Time()
    }
    if hasT { skipSpaces() }
    var time = Time()
    guard let hour = number(digits: 1...2), consume(":"), let minute = number(digits: 2...2),
      (0...23).contains(hour), (0...59).contains(minute)
    else { return nil }
    (time.hour, time.minute) = (hour, minute)
    if consume(":") {
      guard let second = number(digits: 2...2), (0...59).contains(second) else { return nil }
      time.second = second
      if consumeAny(of: [".", ","]) != nil {
        guard let nanosecond = fraction() else { return nil }
        time.nanosecond = nanosecond
      }
    }
    return time
  }

  /// 可选的时区：`Z`、`UTC`、`GMT` 或 `±HH[[:]MM]`；没写时用 `default`。格式不对时返回 nil。
  mutating func zone(default fallback: TimeZone) -> TimeZone? {
    skipSpaces()
    if consumeAny(of: ["Z", "z", "UTC", "GMT"]) != nil { return TimeZone(secondsFromGMT: 0) }
    guard let sign = consumeAny(of: ["+", "-"]) else { return fallback }
    guard let hours = fixed(count: 2), hours <= 23 else { return nil }
    var minutes = 0
    if consume(":") {
      guard let parsed = fixed(count: 2) else { return nil }
      minutes = parsed
    } else if let parsed = fixed(count: 2) {
      minutes = parsed
    }
    guard minutes <= 59 else { return nil }
    let offset = (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)
    return TimeZone(secondsFromGMT: offset)
  }
}
