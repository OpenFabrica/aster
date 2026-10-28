// 内置转换的纯函数：行内结果、内容确认、Base64、URL、Hash、UUID 与随机串。时间与日期在 BuiltinDateParsing.swift。
import CryptoKit
import Foundation

/// 内置转换的纯函数，可在任意线程调用。
public enum BuiltinTextTools {
  /// 随机串长度上限。
  public static let maximumRandomLength = 4_096

  /// 启动器行内显示的结果（`↩` 直接复制）；该输入没有可立即给出的结果时返回 nil。
  /// - 时间戳：10/13 位数字 → 本地时间；常见日期写法 → 秒级时间戳。
  /// - Base64：像 Base64 时给出解码文本。URL：含 `%XX` 且解码有变化时给出解码结果。
  /// - Hash：原样输入（不去首尾空白）的 SHA-256。JSON、端口、UUID 没有行内结果。
  /// `now` 为行内相对时间预留，当前未使用。
  public static func inlineResult(
    _ handler: ToolBuiltinHandler,
    input: String,
    now: Date,
    timeZone: TimeZone
  ) -> String? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    switch handler {
    case .timestamp:
      if let date = parseTimestamp(text) { return formatDate(date, timeZone: timeZone) }
      if let date = parseDate(text, timeZone: timeZone) { return unixSeconds(date) }
      return nil
    case .base64:
      return looksLikeBase64(text) ? base64Decode(text) : nil
    case .url:
      guard let decoded = urlDecode(text), decoded != text else { return nil }
      return decoded
    case .hash:
      return hex(SHA256.hash(data: Data(input.utf8)))
    case .json, .ports, .uuid, .stickies:
      return nil
    }
  }

  /// 内置工具对内容的二次确认。match 正则只是粗筛（例如普通单词也符合 Base64 字符集），
  /// 这里确认内容真能被处理，避免「识别到」误报。没有专门判断的处理器一律接受。
  public static func acceptsContent(_ handler: ToolBuiltinHandler, text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch handler {
    case .timestamp:
      return parseTimestamp(trimmed) != nil || parseDate(trimmed, timeZone: TimeZone(secondsFromGMT: 0) ?? .current) != nil
    case .base64:
      return looksLikeBase64(trimmed)
    case .url:
      if isHTTPURL(trimmed) { return true }
      guard let decoded = urlDecode(trimmed) else { return false }
      return decoded != trimmed
    case .ports:
      return port(trimmed) != nil
    case .hash, .json, .uuid, .stickies:
      return true
    }
  }

  // MARK: Base64

  /// UTF-8 文本编码为标准 Base64（带补位）。
  public static func base64Encode(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
  }

  /// 同时接受标准与 URL 安全字母表（不能混用）、可省略补位、可按行折断；不合法或结果不是 UTF-8 文本时返回 nil。
  public static func base64Decode(_ text: String) -> String? {
    guard let data = base64Data(text) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 看起来像 Base64：去掉空白后至少 8 个字符、字母表与补位合法，且解码结果是非空、可打印的 UTF-8 文本
  /// （允许换行与制表符）。普通单词碰巧符合字符集时，解码出的字节几乎不可能是可打印文本，以此避免误报。
  public static func looksLikeBase64(_ text: String) -> Bool {
    guard text.unicodeScalars.lazy.filter({ !$0.properties.isWhitespace }).count >= 8,
      let decoded = base64Decode(text), !decoded.isEmpty
    else { return false }
    return decoded.unicodeScalars.allSatisfy { scalar in
      scalar == "\n" || scalar == "\r" || scalar == "\t" || (!ToolTextRules.isControl(scalar) && scalar != "\u{FFFD}")
    }
  }

  /// Base64 文本 → 字节；字母表、补位位置或长度不合法时为 nil。
  static func base64Data(_ text: String) -> Data? {
    var body = text.unicodeScalars.filter { !$0.properties.isWhitespace }
    var padding = 0
    while body.last == "=" {
      body.removeLast()
      padding += 1
    }
    guard !body.isEmpty, padding <= 2 else { return nil }
    let standard = body.contains { $0 == "+" || $0 == "/" }
    let urlSafe = body.contains { $0 == "-" || $0 == "_" }
    guard !(standard && urlSafe),
      body.allSatisfy({ ToolTextRules.isAlphanumeric($0) || "+/-_".unicodeScalars.contains($0) })
    else { return nil }
    // 有补位时总长必须是 4 的倍数；没有补位时长度除 4 余 1 不可能是合法编码。
    if padding > 0 {
      guard (body.count + padding) % 4 == 0 else { return nil }
    } else {
      guard body.count % 4 != 1 else { return nil }
    }
    var normalized = String(String.UnicodeScalarView(body.map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 }))
    normalized += String(repeating: "=", count: (4 - normalized.unicodeScalars.count % 4) % 4)
    return Data(base64Encoded: normalized)
  }

  // MARK: URL

  /// RFC 3986 的非保留字符；只认 ASCII，`CharacterSet.alphanumerics` 会把汉字也当成不需要编码。
  private static let urlUnreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// 百分号编码：除 `A–Z a–z 0–9 - . _ ~` 外的字节都编码。
  public static func urlEncode(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: urlUnreserved) ?? text
  }

  /// 百分号解码；`%` 序列不合法时为 nil。`+` 保持原样，只有表单查询里它才表示空格（见 `urlComponents`）。
  public static func urlDecode(_ text: String) -> String? {
    text.removingPercentEncoding
  }

  /// 是不是 http(s) 地址：协议为 http/https 且有主机，不含空白。
  public static func isHTTPURL(_ text: String) -> Bool {
    guard !text.contains(where: \.isWhitespace), let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host
    else { return false }
    return !host.isEmpty
  }

  /// 拆 URL：协议、主机、端口、路径、每个查询参数（名字作标签）、片段。也接受只有查询串的 `a=1&b=2`（可带前导 `?`）。
  /// 查询参数按表单规则解码（`+` 当空格，与浏览器 `URLSearchParams` 一致）。都不是时返回 nil。
  public static func urlComponents(_ text: String) -> [ToolResultLine]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
    if let components = URLComponents(string: trimmed), let scheme = components.scheme,
      let host = components.host, !host.isEmpty
    {
      var lines = [ToolResultLine(label: L("协议"), value: scheme), ToolResultLine(label: L("主机"), value: host)]
      if let port = components.port { lines.append(ToolResultLine(label: L("端口号"), value: String(port))) }
      if !components.path.isEmpty { lines.append(ToolResultLine(label: L("路径"), value: components.path)) }
      lines += queryLines(rawQuery(of: trimmed))
      if let fragment = components.fragment, !fragment.isEmpty {
        lines.append(ToolResultLine(label: L("片段标识"), value: fragment))
      }
      return lines
    }
    let query = trimmed.hasPrefix("?") ? String(trimmed.dropFirst()) : trimmed
    guard query.contains("="), isBareQuery(query) else { return nil }
    let lines = queryLines(query)
    return lines.isEmpty ? nil : lines
  }

  /// 原文里 `?` 到 `#` 之间的查询串。不用 `URLComponents.percentEncodedQuery`：只要有一个非法 `%` 序列，
  /// 它会把整段查询重新编码一遍，好参数也就解不回来了。
  static func rawQuery(of url: String) -> String? {
    let beforeFragment = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard let mark = beforeFragment.firstIndex(of: "?") else { return nil }
    return String(beforeFragment[beforeFragment.index(after: mark)...])
  }

  /// 没有协议时，只有每个参数名都不含 `/ : ? #` 才当作查询串，`localhost:8080/a?x=1` 这类地址不会被误拆。
  private static func isBareQuery(_ query: String) -> Bool {
    query.split(separator: "&").allSatisfy { pair in
      let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
      return !name.contains { "/:?#".contains($0) }
    }
  }

  /// 查询串拆成参数行：按 `&` 分隔，名字与值按表单规则解码。
  static func queryLines(_ query: String?) -> [ToolResultLine] {
    guard let query, !query.isEmpty else { return [] }
    return query.split(separator: "&").map { pair in
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let value = parts.count > 1 ? formDecode(String(parts[1])) : ""
      return ToolResultLine(label: formDecode(String(parts[0])), value: value)
    }
  }

  /// 表单解码：`+` 当空格再做百分号解码；`%` 序列不合法时显示原文，不让一个坏参数吞掉整行。
  static func formDecode(_ text: String) -> String {
    let spaced = text.replacingOccurrences(of: "+", with: " ")
    return spaced.removingPercentEncoding ?? spaced
  }

  // MARK: 端口

  /// 端口号（可带前导冒号与首尾空白）：1–65535，只认 ASCII 数字。
  public static func port(_ text: String) -> Int? {
    var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    if digits.hasPrefix(":") { digits = digits.dropFirst() }
    guard (1...5).contains(digits.count), digits.unicodeScalars.allSatisfy(ToolTextRules.isDigit),
      let value = Int(digits), (1...65_535).contains(value)
    else { return nil }
    return value
  }

  // MARK: Hash

  /// MD5、SHA-1、SHA-256、SHA-512 的十六进制结果。
  public static func hashes(of data: Data) -> [ToolResultLine] {
    [
      ToolResultLine(label: "MD5", value: hex(Insecure.MD5.hash(data: data))),
      ToolResultLine(label: "SHA-1", value: hex(Insecure.SHA1.hash(data: data))),
      ToolResultLine(label: "SHA-256", value: hex(SHA256.hash(data: data))),
      ToolResultLine(label: "SHA-512", value: hex(SHA512.hash(data: data))),
    ]
  }

  /// 小写十六进制。
  static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    let digits = Array("0123456789abcdef".unicodeScalars)
    var scalars = String.UnicodeScalarView()
    for byte in bytes {
      scalars.append(digits[Int(byte >> 4)])
      scalars.append(digits[Int(byte & 0x0F)])
    }
    return String(scalars)
  }

  // MARK: UUID 与随机串

  /// 随机 UUID v4（小写）。
  public static func uuidV4() -> String {
    UUID().uuidString.lowercased()
  }

  /// 时间有序的 UUID v7（RFC 9562）：前 48 位是 Unix 毫秒，其余为安全随机数，带版本与变体位。
  public static func uuidV7(now: Date) -> String {
    let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
    var generator = SystemRandomNumberGenerator()
    var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
    for index in 0..<6 { bytes[index] = UInt8((milliseconds >> (8 * UInt64(5 - index))) & 0xFF) }
    bytes[6] = (bytes[6] & 0x0F) | 0x70
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return uuid.uuidString.lowercased()
  }

  /// 用系统安全随机数生成随机串；长度限制在 0...4096。
  public static func randomString(length: Int, alphabet: ToolRandomAlphabet) -> String {
    let characters: [Character] =
      switch alphabet {
      case .alphanumeric: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
      case .hex: Array("0123456789abcdef")
      case .symbols: Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+[]{}")
      }
    var generator = SystemRandomNumberGenerator()
    let count = max(0, min(length, maximumRandomLength))
    return String((0..<count).map { _ in characters[Int.random(in: characters.indices, using: &generator)] })
  }
}
