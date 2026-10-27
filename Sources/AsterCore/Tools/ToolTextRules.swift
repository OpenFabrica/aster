// 工具模块共用的文本判定：控制字符、标识符字符集、主机名、按字节截断。只做纯判断，不带界面文案。
import Foundation

enum ToolTextRules {
  /// 双向文本控制符。它们能让安装确认里显示的名字与实际内容不一致，所以和控制字符一样拒绝。
  private static let bidiControls: Set<UInt32> = [
    0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
  ]

  /// 是否含控制字符（Cc）、行/段分隔符或双向文本控制符。
  static func containsControlCharacters(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isControl)
  }

  /// 单个标量是否属于上面定义的「控制字符」。
  static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator: true
    default: bidiControls.contains(scalar.value)
    }
  }

  /// ASCII 小写字母或数字。
  static func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || isDigit(scalar)
  }

  /// ASCII 数字。`\d` 在 ICU 里还会匹配全角等数字，规则里的数字都只认 ASCII。
  static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar)
  }

  /// ASCII 字母或数字。
  static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    isLowerAlphanumeric(scalar) || ("A"..."Z").contains(scalar)
  }

  /// 清单 `network` 里的一项：小写主机名或 `*.主机名`，不含协议、端口、路径。
  /// 每段 1–63 个 `[a-z0-9-]`、不以连字符开头或结尾，总长 ≤ 253。
  static func isValidHostPattern(_ pattern: String) -> Bool {
    let host = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
    guard !host.isEmpty, host.utf8.count <= 253 else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
      return label.unicodeScalars.allSatisfy { isLowerAlphanumeric($0) || $0 == "-" }
    }
  }

  /// 取不超过 `maximumBytes` 个 UTF-8 字节的前缀，只在字符边界截断。
  static func prefix(_ text: String, maximumUTF8Bytes maximumBytes: Int) -> String {
    guard text.utf8.count > maximumBytes else { return text }
    var result = ""
    var used = 0
    for character in text {
      let size = character.utf8.count
      guard used + size <= maximumBytes else { break }
      result.append(character)
      used += size
    }
    return result
  }

  /// 展示用的单行文本：控制字符与换行换成空格，超过 `maximumCharacters` 时截断并以 `…` 结尾。
  static func singleLine(_ text: String, maximumCharacters: Int) -> String {
    var line = String(String.UnicodeScalarView(text.unicodeScalars.map { isControl($0) ? " " : $0 }))
    if line.count > maximumCharacters {
      line = String(line.prefix(max(0, maximumCharacters - 1))) + "…"
    }
    return line
  }
}
