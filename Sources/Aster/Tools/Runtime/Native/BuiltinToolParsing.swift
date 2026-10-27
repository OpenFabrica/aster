// 内置原生工具的纯函数：日期解析、URL 拆分、端口过滤、Base64 默认模式与随机串长度。不依赖界面，便于单测。
import AsterCore
import Foundation

// MARK: - 日期

/// 常见日期写法解析（时间戳工具的「日期 → 时间戳」方向）。
enum BuiltinDateParser {
  /// 带时区偏移的写法在前（含时间戳工具自己输出的 `yyyy-MM-dd HH:mm:ss xxx`，复制回来能原样解析），
  /// 无时区的写法在后，按调用方给的时区理解。DateFormatter 不宽松匹配，尾部多出的内容会让该格式失败。
  private static let formats = [
    "yyyy-MM-dd HH:mm:ss xxx",
    "yyyy-MM-dd HH:mm:ss Z",
    "yyyy-MM-dd'T'HH:mm:ssZ",
    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
    "yyyy-MM-dd'T'HH:mm:ss.SSS",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm",
    "yyyy-MM-dd HH:mm:ss.SSS",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd HH:mm",
    "yyyy/MM/dd HH:mm:ss",
    "yyyy/MM/dd HH:mm",
    "yyyy-MM-dd",
    "yyyy/MM/dd",
  ]

  /// 解析日期；无时区的写法按 `timeZone` 理解。认不出返回 nil。
  static func parse(_ text: String, timeZone: TimeZone) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
    // ISO 8601（`Z` 或 `±HH:mm` 时区，可带小数秒）交给专门的解析器，DateFormatter 的模式写不全这些变体。
    let isoOptions: [ISO8601DateFormatter.Options] = [
      [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
    ]
    for options in isoOptions {
      let iso = ISO8601DateFormatter()
      iso.formatOptions = options
      if let date = iso.date(from: trimmed) { return date }
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.isLenient = false
    for format in formats {
      formatter.dateFormat = format
      if let date = formatter.date(from: trimmed) { return date }
    }
    return nil
  }
}

// MARK: - URL

/// URL 拆分结果：协议、主机、端口、路径、锚点（`#` 之后的片段）与解码后的查询参数。
struct BuiltinURLParts: Equatable {
  var scheme: String?
  var host: String?
  var port: Int?
  var path: String?
  var fragment: String?
  /// 解码后的参数，按出现顺序；同名参数保留多条。
  var parameters: [ToolResultLine]

  /// 界面上的各行：先是 URL 各部分，再是每个参数一行（参数名作标签），最后是锚点。
  var lines: [ToolResultLine] {
    var lines: [ToolResultLine] = []
    if let scheme { lines.append(ToolResultLine(label: L("协议"), value: scheme)) }
    if let host { lines.append(ToolResultLine(label: L("主机"), value: host)) }
    if let port { lines.append(ToolResultLine(label: L("端口号"), value: String(port))) }
    if let path, !path.isEmpty { lines.append(ToolResultLine(label: L("路径"), value: path)) }
    lines += parameters
    if let fragment, !fragment.isEmpty { lines.append(ToolResultLine(label: L("锚点"), value: fragment)) }
    return lines
  }

  /// 参数写成 `名=值` 的多行文本（解码后）；没有参数时 nil。
  var parametersText: String? {
    parameters.isEmpty ? nil : parameters.map { "\($0.label)=\($0.value)" }.joined(separator: "\n")
  }

  /// 拆分完整 URL（`scheme://host/path?query#fragment`）或单独的查询串（`a=1&b=2`、`?a=1`）；都不是返回 nil。
  ///
  /// 查询串手工拆分而不交给 `URLComponents.queryItems`：后者不把 `+` 当空格，而表单编码的查询里
  /// `+` 就是空格；先把 `+` 换成空格再做百分号解码，原文里的 `%2B` 仍会还原成 `+`。
  static func parse(_ text: String) -> BuiltinURLParts? {
    var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rest.isEmpty else { return nil }
    var parts = BuiltinURLParts(parameters: [])
    if let hash = rest.firstIndex(of: "#") {
      parts.fragment = decodeComponent(String(rest[rest.index(after: hash)...]), plusAsSpace: false)
      rest = String(rest[..<hash])
    }
    var query: String?
    if let mark = rest.firstIndex(of: "?") {
      query = String(rest[rest.index(after: mark)...])
      rest = String(rest[..<mark])
    }
    if rest.contains("://") {
      parts.applyBase(rest)
    } else if query == nil, rest.contains("=") {
      query = rest
    } else if !rest.isEmpty {
      return nil
    }
    parts.parameters = query.map(parseQuery) ?? []
    guard parts.scheme != nil || !parts.parameters.isEmpty else { return nil }
    return parts
  }

  /// 拆 `scheme://host:port/path`：优先用 `URLComponents`，含空格、中文等它不接受的字符时手工切分。
  private mutating func applyBase(_ base: String) {
    if let components = URLComponents(string: base), let scheme = components.scheme {
      self.scheme = scheme
      host = components.host
      port = components.port
      path = components.path
      return
    }
    guard let separator = base.range(of: "://") else { return }
    scheme = String(base[..<separator.lowerBound])
    let afterScheme = base[separator.upperBound...]
    let slash = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
    host = String(afterScheme[..<slash])
    path = Self.decodeComponent(String(afterScheme[slash...]), plusAsSpace: false)
  }

  /// `a=1&b=2&c` → 三行；空段跳过，缺 `=` 的参数值为空。
  static func parseQuery(_ query: String) -> [ToolResultLine] {
    query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
      let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = decodeComponent(String(pieces[0]), plusAsSpace: true)
      let value = pieces.count > 1 ? decodeComponent(String(pieces[1]), plusAsSpace: true) : ""
      return ToolResultLine(label: name, value: value)
    }
  }

  /// 百分号解码；编码不合法时保留原文，不让一个坏参数吞掉整张表。
  private static func decodeComponent(_ raw: String, plusAsSpace: Bool) -> String {
    let spaced = plusAsSpace ? raw.replacingOccurrences(of: "+", with: " ") : raw
    return spaced.removingPercentEncoding ?? spaced
  }
}

/// URL 工具的三种模式。
enum BuiltinURLMode: Int, CaseIterable {
  case encode
  case decode
  case split

  /// 默认模式：含 `%XX` → 解码；`http(s)://` 且带查询 → 拆参数；否则编码。
  static func preferred(for text: String) -> BuiltinURLMode {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil { return .decode }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://"), trimmed.contains("?") { return .split }
    return .encode
  }
}

// MARK: - 端口

/// 端口工具的过滤与排序。
enum BuiltinPortFilter {
  /// `3000`、`:3000` → 3000；其它文本（含空）返回 nil，表示不过滤。
  static func port(from text: String?) -> Int? {
    var trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix(":") { trimmed.removeFirst() }
    guard (1...5).contains(trimmed.count), trimmed.allSatisfy(\.isASCII), let port = Int(trimmed),
      (1...65_535).contains(port)
    else { return nil }
    return port
  }

  /// 端点（`*:3000`、`127.0.0.1:3000`、`[::1]:3000`）里的端口号。
  static func portNumber(of endpoint: String) -> Int? {
    guard let colon = endpoint.lastIndex(of: ":") else { return nil }
    return Int(endpoint[endpoint.index(after: colon)...])
  }

  /// 只保留指定端口（nil 不过滤），按端口号、端点、PID 排序，刷新时行序稳定。
  static func filtered(_ ports: [ListeningPort], port: Int?) -> [ListeningPort] {
    ports
      .filter { port == nil || portNumber(of: $0.endpoint) == port }
      .sorted { lhs, rhs in
        let left = portNumber(of: lhs.endpoint) ?? 0
        let right = portNumber(of: rhs.endpoint) ?? 0
        if left != right { return left < right }
        if lhs.endpoint != rhs.endpoint { return lhs.endpoint < rhs.endpoint }
        return lhs.processIdentifier < rhs.processIdentifier
      }
  }
}

// MARK: - Base64

/// Base64 工具的解码与默认模式。
enum BuiltinBase64 {
  /// 去掉空白后解码：按 76 列折行的 Base64 很常见。结果不是 UTF-8 文本时返回 nil。
  static func decode(_ text: String) -> String? {
    let compact = text.filter { !$0.isWhitespace }
    guard !compact.isEmpty else { return nil }
    return BuiltinTextTools.base64Decode(compact)
  }

  /// 默认模式：能解成像样的文本（不含换行与制表以外的控制字符）就解码，否则编码。
  /// 只看能否解码会把 `AAAA` 这类输入解成一串 NUL，所以还要排除控制字符。
  static func prefersDecoding(_ text: String) -> Bool {
    guard let decoded = decode(text), !decoded.isEmpty else { return false }
    let allowed: Set<Unicode.Scalar> = ["\n", "\r", "\t"]
    return decoded.unicodeScalars.allSatisfy {
      !CharacterSet.controlCharacters.contains($0) || allowed.contains($0)
    }
  }
}

// MARK: - 随机串

/// 随机串长度输入。
enum BuiltinRandomLength {
  static let range = 1...4_096
  static let defaultLength = 32

  /// 解析长度；不是 1–4096 的整数返回 nil。
  static func parse(_ text: String) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else {
      return nil
    }
    return value
  }
}
