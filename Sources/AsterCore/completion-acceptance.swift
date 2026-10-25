// 将接受候选转换为终端删除和插入字节，不执行 Shell 展开。

/// Otty 接受候选的替换规则。删除单位是 Unicode scalar，不是字节或字素簇。
public enum CompletionAcceptance {
  /// 返回应发送给 PTY 的字节：DEL 删除原始输入，再插入候选及适用的尾空格。
  /// correction 与 learnedCommand 替换整行，其余类型替换最后一个原始 token；
  /// replacement 偏移不参与此规则。文件和目录使用未转义的 displayText，按原生
  /// 路径集合编码；其它已恢复类型原样插入 insertText。
  /// 空候选或包含 Unicode 控制字符时返回 nil。原版可能保留含 Tab 的规格字面值，
  /// 此处拒绝它们，避免候选触发 Shell 补全、执行命令或改变终端状态。
  public static func bytes(candidate: AutocompleteCandidate, line: String) -> [UInt8]? {
    let isPath = candidate.kind == .file || candidate.kind == .folder
    let text = isPath ? candidate.displayText : candidate.insertText
    guard !text.isEmpty,
      !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else { return nil }

    switch candidate.kind {
    case .snippet, .readmeCommand, .followUp, .clipboard:
      // 这些类型的原生动作/body 分支尚未恢复，保留既有的只追加兼容行为。
      return candidate.appendableSuffix(from: line).map { Array($0.utf8) }
    default:
      break
    }

    let rawToken = lastRawToken(line)
    let replacesLine = candidate.kind == .correction || candidate.kind == .learnedCommand
    let deletionCount = replacesLine ? line.unicodeScalars.count : rawToken.unicodeScalars.count
    var result = Array(repeating: UInt8(0x7f), count: deletionCount)
    result.append(contentsOf: (isPath ? escapePath(text, rawToken: rawToken) : text).utf8)
    if candidate.kind != .folder && !replacesLine {
      // 普通类型即使自带尾空格也仍追加一个 ASCII 空格。
      result.append(0x20)
    }
    return result
  }

  /// 原生边界扫描按 Character 判断 ASCII 空格，引号和反斜杠保留在原始 suffix；
  /// 返回后再按 Unicode scalar 计算删除数，两个单位不能混用。
  private static func lastRawToken(_ line: String) -> Substring {
    var quote: Character?
    var escaped = false
    var start = line.startIndex
    for index in line.indices {
      let character = line[index]
      if escaped {
        escaped = false
      } else if character == "\\", quote != "'" {
        escaped = true
      } else if let activeQuote = quote {
        if character == activeQuote { quote = nil }
      } else if character == "'" || character == "\"" {
        quote = character
      } else if character == " " {
        start = line.index(after: index)
      }
    }
    return line[start...]
  }

  private static let pathEscapes = Set(" ()&|;$!><`\\\"'*?[]{}~#^\n\t")

  private static func escapePath(_ text: String, rawToken: Substring) -> String {
    var result = ""
    for character in text {
      if pathEscapes.contains(character) { result.append("\\") }
      result.append(character)
    }
    if ShellCommandTokenizer.tokenize(String(rawToken)).tokens.first?.hasPrefix("~") == true,
      result.hasPrefix("\\~")
    {
      result.removeFirst()
    }
    return result
  }
}
