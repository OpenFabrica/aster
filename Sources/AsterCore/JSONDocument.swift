// File Pane 的 JSON 树视图与格式化共用的保序解析器和排版器。
import Foundation

/// 保留原文键顺序与重复键的 JSON 值。不用 `JSONSerialization`：它会按字典打乱
/// 键顺序，并把数字转成浮点后改写原文（大整数丢精度、`1.0` 变 `1`）。
public indirect enum JSONNode: Equatable, Sendable {
  case object([JSONMember])
  case array([JSONNode])
  case string(String)
  /// 数字保存原文字面量。
  case number(String)
  case bool(Bool)
  case null

  /// 容器的直接子项数量；标量为 nil。
  public var childCount: Int? {
    switch self {
    case .object(let members): members.count
    case .array(let items): items.count
    default: nil
    }
  }
}

/// 对象中的一个键值对；同一对象允许出现重复键，按原文顺序保留。
public struct JSONMember: Equatable, Sendable {
  public let key: String
  public let value: JSONNode

  public init(key: String, value: JSONNode) {
    self.key = key
    self.value = value
  }
}

/// JSON 语法错误及其在原文中的位置。行列从 1 开始，列按字符（非字节）计数。
public struct JSONParseError: Error, Equatable, Sendable {
  public enum Reason: Equatable, Sendable {
    case unexpectedEnd
    case unexpectedCharacter
    case invalidString
    case invalidNumber
    /// 嵌套超过 `JSONDocumentParser.maximumDepth`，用来防止递归解析栈溢出。
    case tooDeep
    case trailingContent
    /// 调用方任务已取消；渲染管线应丢弃结果而不是显示错误。
    case cancelled
  }

  public let reason: Reason
  public let line: Int
  public let column: Int

  public init(reason: Reason, line: Int, column: Int) {
    self.reason = reason
    self.line = line
    self.column = column
  }
}

/// RFC 8259 解析器，直接扫描 UTF-8 字节。
public enum JSONDocumentParser {
  /// 嵌套上限。解析本身用显式栈不受线程栈限制；这个上限约束的是树节点释放、
  /// 序列化等仍按层递归的下游操作，也拦住恶意的超深文档。
  public static let maximumDepth = 512

  /// 解析整篇文档；开头的 UTF-8 BOM 会被忽略。失败抛出 `JSONParseError`。
  public static func parse(_ text: String) throws -> JSONNode {
    var scanner = JSONByteScanner(bytes: Array(text.utf8))
    scanner.skipByteOrderMark()
    let value = try scanner.parseDocument()
    scanner.skipWhitespace()
    guard scanner.isAtEnd else { throw scanner.error(.trailingContent) }
    return value
  }
}

/// 解析器内部状态。只在单次 `parse` 调用里使用，不跨线程共享。
private struct JSONByteScanner {
  /// 尚未闭合的容器。对象帧带着下一个值所属的键。
  private enum Frame {
    case object([JSONMember], key: String)
    case array([JSONNode])
  }

  let bytes: [UInt8]
  var index = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  var isAtEnd: Bool { index >= bytes.count }

  mutating func skipByteOrderMark() {
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
  }

  mutating func skipWhitespace() {
    while index < bytes.count, JSONBytes.isWhitespace(bytes[index]) { index += 1 }
  }

  /// 用显式栈解析一个完整值。递归下降在后台线程（栈只有 512 KiB）上解析几百层
  /// 嵌套就会栈溢出，所以这里把“打开的容器”放进数组：外层循环读一个值的开头，
  /// 内层循环把读完的值挂到栈顶容器上，并在遇到 `]` / `}` 时逐层闭合。
  mutating func parseDocument() throws -> JSONNode {
    var stack: [Frame] = []
    var parsedValues = 0
    while true {
      // 每 1024 个值检查一次取消，让后台渲染在新修订到来时尽快让出 CPU。
      parsedValues += 1
      if parsedValues & 1023 == 0, Task.isCancelled { throw error(.cancelled) }
      skipWhitespace()
      guard index < bytes.count else { throw error(.unexpectedEnd) }
      var value: JSONNode
      switch bytes[index] {
      case UInt8(ascii: "{"):
        guard stack.count < JSONDocumentParser.maximumDepth else { throw error(.tooDeep) }
        index += 1
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
          index += 1
          value = .object([])
        } else {
          stack.append(.object([], key: try parseKey()))
          continue
        }
      case UInt8(ascii: "["):
        guard stack.count < JSONDocumentParser.maximumDepth else { throw error(.tooDeep) }
        index += 1
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
          index += 1
          value = .array([])
        } else {
          stack.append(.array([]))
          continue
        }
      case UInt8(ascii: "\""): value = .string(try parseString())
      case UInt8(ascii: "t"): try expectLiteral("true"); value = .bool(true)
      case UInt8(ascii: "f"): try expectLiteral("false"); value = .bool(false)
      case UInt8(ascii: "n"): try expectLiteral("null"); value = .null
      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): value = .number(try parseNumber())
      default: throw error(.unexpectedCharacter)
      }

      // 把完成的值交给父容器；父容器随之闭合时继续向外交付，遇到 `,` 则回到外层读下一个值。
      attach: while true {
        guard let frame = stack.popLast() else { return value }
        skipWhitespace()
        guard index < bytes.count else { throw error(.unexpectedEnd) }
        let next = bytes[index]
        switch frame {
        case .array(var items):
          items.append(value)
          if next == UInt8(ascii: ",") {
            index += 1
            stack.append(.array(items))
            break attach
          }
          guard next == UInt8(ascii: "]") else { throw error(.unexpectedCharacter) }
          index += 1
          value = .array(items)
        case .object(var members, let key):
          members.append(JSONMember(key: key, value: value))
          if next == UInt8(ascii: ",") {
            index += 1
            stack.append(.object(members, key: try parseKey()))
            break attach
          }
          guard next == UInt8(ascii: "}") else { throw error(.unexpectedCharacter) }
          index += 1
          value = .object(members)
        }
      }
    }
  }

  /// 读对象成员的 `"键" :`，停在值的开头之前。
  private mutating func parseKey() throws -> String {
    skipWhitespace()
    guard index < bytes.count else { throw error(.unexpectedEnd) }
    guard bytes[index] == UInt8(ascii: "\"") else { throw error(.unexpectedCharacter) }
    let key = try parseString()
    skipWhitespace()
    try expect(UInt8(ascii: ":"))
    return key
  }

  /// 解码字符串字面量。未配对的 UTF-16 代理在语法上合法，按 U+FFFD 显示而不报错。
  private mutating func parseString() throws -> String {
    index += 1
    var output: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      switch byte {
      case UInt8(ascii: "\""):
        index += 1
        return String(decoding: output, as: UTF8.self)
      case UInt8(ascii: "\\"):
        index += 1
        guard index < bytes.count else { throw error(.unexpectedEnd) }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): output.append(escape)
        case UInt8(ascii: "b"): output.append(0x08)
        case UInt8(ascii: "f"): output.append(0x0C)
        case UInt8(ascii: "n"): output.append(0x0A)
        case UInt8(ascii: "r"): output.append(0x0D)
        case UInt8(ascii: "t"): output.append(0x09)
        case UInt8(ascii: "u"): output.append(contentsOf: try parseUnicodeEscape())
        default:
          index -= 1
          throw error(.invalidString)
        }
      case 0x00..<0x20:
        throw error(.invalidString)
      default:
        output.append(byte)
        index += 1
      }
    }
    throw error(.unexpectedEnd)
  }

  /// 读 `\u` 之后的 4 位十六进制；高代理后紧跟 `\uDC00…` 时合并成一个标量。
  private mutating func parseUnicodeEscape() throws -> [UInt8] {
    let high = try readHex4()
    var scalarValue = UInt32(high)
    if (0xD800...0xDBFF).contains(high), index + 1 < bytes.count,
      bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
    {
      let saved = index
      index += 2
      let low = try readHex4()
      if (0xDC00...0xDFFF).contains(low) {
        scalarValue = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
      } else {
        index = saved
      }
    }
    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
    return Array(String(Character(scalar)).utf8)
  }

  private mutating func readHex4() throws -> UInt16 {
    guard index + 4 <= bytes.count else { throw error(.unexpectedEnd) }
    var value: UInt16 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      let digit: UInt16
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
      default: throw error(.invalidString)
      }
      value = value << 4 | digit
      index += 1
    }
    return value
  }

  /// 按 JSON 数字语法校验并返回原文：`-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?`。
  private mutating func parseNumber() throws -> String {
    let start = index
    if bytes[index] == UInt8(ascii: "-") { index += 1 }
    guard index < bytes.count, JSONBytes.isDigit(bytes[index]) else { throw error(.invalidNumber) }
    if bytes[index] == UInt8(ascii: "0") {
      index += 1
    } else {
      while index < bytes.count, JSONBytes.isDigit(bytes[index]) { index += 1 }
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      index += 1
      guard index < bytes.count, JSONBytes.isDigit(bytes[index]) else { throw error(.invalidNumber) }
      while index < bytes.count, JSONBytes.isDigit(bytes[index]) { index += 1 }
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      index += 1
      if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
        index += 1
      }
      guard index < bytes.count, JSONBytes.isDigit(bytes[index]) else { throw error(.invalidNumber) }
      while index < bytes.count, JSONBytes.isDigit(bytes[index]) { index += 1 }
    }
    return String(decoding: bytes[start..<index], as: UTF8.self)
  }

  private mutating func expectLiteral(_ literal: String) throws {
    for byte in literal.utf8 {
      guard index < bytes.count else { throw error(.unexpectedEnd) }
      guard bytes[index] == byte else { throw error(.unexpectedCharacter) }
      index += 1
    }
  }

  private mutating func expect(_ byte: UInt8) throws {
    guard index < bytes.count else { throw error(.unexpectedEnd) }
    guard bytes[index] == byte else { throw error(.unexpectedCharacter) }
    index += 1
  }

  /// 把当前字节偏移换算成 1 起始的行列；列按字符计，中文等多字节字符算一列。
  func error(_ reason: JSONParseError.Reason) -> JSONParseError {
    let end = min(index, bytes.count)
    var line = 1
    var lineStart = 0
    for position in 0..<end where bytes[position] == 0x0A {
      line += 1
      lineStart = position + 1
    }
    let column = String(decoding: bytes[lineStart..<end], as: UTF8.self).count + 1
    return JSONParseError(reason: reason, line: line, column: column)
  }
}

/// 字节分类小工具，解析器与排版器共用。
private enum JSONBytes {
  static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }

  static func isDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
  }
}

/// JSON 排版。格式化只改 token 之间的空白：字符串、数字和字面量逐字节原样拷贝，
/// 因此 `\u4e2d` 这类转义、大整数和 `1.0` 都不会被改写。
public enum JSONDocumentFormatter {
  /// 校验后按 `indent` 缩进重排；空容器保持 `{}` / `[]`，末尾补一个换行。
  public static func format(_ text: String, indent: String) throws -> String {
    _ = try JSONDocumentParser.parse(text)
    return rewrite(text, indent: indent)
  }

  /// 校验后去掉 token 之间的全部空白。
  public static func minify(_ text: String) throws -> String {
    _ = try JSONDocumentParser.parse(text)
    return rewrite(text, indent: nil)
  }

  /// 沿用文档已有的缩进单位：第一条有缩进的行在合法 JSON 中位于第 1 层，它的前导
  /// 空白即单位缩进。找不到（如单行压缩文件）时用两个空格。
  public static func detectIndent(in text: String) -> String {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
      let leading = line.prefix { $0 == " " || $0 == "\t" }
      guard !leading.isEmpty, leading.count < line.count else { continue }
      if leading.first == "\t" { return "\t" }
      return (1...8).contains(leading.count) ? String(leading) : "  "
    }
    return "  "
  }

  /// 把解析后的值序列化成 JSON 文本，用于树视图“复制值”。字符串按最小转义输出。
  public static func serialize(_ node: JSONNode, indent: String) -> String {
    var output = ""
    append(node, to: &output, indent: indent, level: 0)
    return output
  }

  /// JSON 字符串字面量（含引号），只转义引号、反斜杠和控制字符。
  public static func quoted(_ string: String) -> String {
    var output = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      case "\u{00}"..."\u{1F}": output += String(format: "\\u%04x", scalar.value)
      default: output.unicodeScalars.append(scalar)
      }
    }
    return output + "\""
  }

  private static func append(_ node: JSONNode, to output: inout String, indent: String, level: Int) {
    let pad = String(repeating: indent, count: level + 1)
    let closePad = String(repeating: indent, count: level)
    switch node {
    case .object(let members):
      guard !members.isEmpty else { output += "{}"; return }
      output += "{\n"
      for (offset, member) in members.enumerated() {
        output += pad + quoted(member.key) + ": "
        append(member.value, to: &output, indent: indent, level: level + 1)
        output += offset == members.count - 1 ? "\n" : ",\n"
      }
      output += closePad + "}"
    case .array(let items):
      guard !items.isEmpty else { output += "[]"; return }
      output += "[\n"
      for (offset, item) in items.enumerated() {
        output += pad
        append(item, to: &output, indent: indent, level: level + 1)
        output += offset == items.count - 1 ? "\n" : ",\n"
      }
      output += closePad + "]"
    case .string(let value): output += quoted(value)
    case .number(let raw): output += raw
    case .bool(let value): output += value ? "true" : "false"
    case .null: output += "null"
    }
  }

  /// 已校验文本的 token 级重排。`indent == nil` 表示压缩。前提是输入合法，
  /// 因此这里只跟踪字符串边界与嵌套层级，不再做语法判断。
  private static func rewrite(_ text: String, indent: String?) -> String {
    let bytes = Array(text.utf8)
    let indentBytes = indent.map { Array($0.utf8) }
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count + bytes.count / 4)
    var level = 0
    var index = 0
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
      output.append(contentsOf: bytes[0..<3])
      index = 3
    }

    func newline() {
      guard let indentBytes else { return }
      output.append(0x0A)
      for _ in 0..<level { output.append(contentsOf: indentBytes) }
    }

    while index < bytes.count {
      let byte = bytes[index]
      switch byte {
      case _ where JSONBytes.isWhitespace(byte):
        index += 1
      case UInt8(ascii: "\""):
        // 字符串整体照抄；只需识别反斜杠转义，避免把 `\"` 当作结束引号。
        let start = index
        index += 1
        while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
          index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
        }
        index = min(index + 1, bytes.count)
        output.append(contentsOf: bytes[start..<index])
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        let close = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
        var lookahead = index + 1
        while lookahead < bytes.count, JSONBytes.isWhitespace(bytes[lookahead]) { lookahead += 1 }
        if lookahead < bytes.count, bytes[lookahead] == close {
          output.append(byte)
          output.append(close)
          index = lookahead + 1
        } else {
          output.append(byte)
          level += 1
          newline()
          index += 1
        }
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        level -= 1
        newline()
        output.append(byte)
        index += 1
      case UInt8(ascii: ","):
        output.append(byte)
        newline()
        index += 1
      case UInt8(ascii: ":"):
        output.append(byte)
        if indentBytes != nil { output.append(0x20) }
        index += 1
      default:
        output.append(byte)
        index += 1
      }
    }
    if indentBytes != nil { output.append(0x0A) }
    return String(decoding: output, as: UTF8.self)
  }
}

/// 树节点在文档中的一步路径：对象键或数组下标。
public enum JSONPathComponent: Hashable, Sendable {
  case key(String)
  case index(Int)
}

/// 生成 JavaScript 风格的路径字符串，如 `$.flashes[0].title`；非标识符键写成 `["a b"]`。
public enum JSONPath {
  public static func string(_ components: [JSONPathComponent]) -> String {
    var output = "$"
    for component in components {
      switch component {
      case .index(let index): output += "[\(index)]"
      case .key(let key):
        output += isIdentifier(key) ? "." + key : "[" + JSONDocumentFormatter.quoted(key) + "]"
      }
    }
    return output
  }

  private static func isIdentifier(_ key: String) -> Bool {
    guard let first = key.unicodeScalars.first,
      first == "_" || first == "$" || (first.isASCII && CharacterSet.letters.contains(first))
    else { return false }
    return key.unicodeScalars.allSatisfy {
      $0 == "_" || $0 == "$" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
    }
  }
}
