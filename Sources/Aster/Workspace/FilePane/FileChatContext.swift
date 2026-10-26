// 发送前冻结的文件引用与选区，始终来自当前视图而非重新读取磁盘。
import Foundation

struct FileChatContext: Equatable {
  let path: String
  let selection: String?
  let lines: ClosedRange<Int>?

  static func capture(path: String, text: String, range: NSRange) -> FileChatContext {
    guard range.length > 0, let selectedRange = Range(range, in: text) else {
      return FileChatContext(path: path, selection: nil, lines: nil)
    }
    func lineBreaks(_ value: String) -> Int {
      value.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n").filter { $0 == "\n" }.count
    }
    let start = lineBreaks(String(text[..<selectedRange.lowerBound])) + 1
    let selected = String(text[selectedRange])
    let end = start + lineBreaks(String(selected.dropLast()))
    return FileChatContext(path: path, selection: selected, lines: start...end)
  }

  func rendered(includeSelection: Bool) -> String {
    var value = "Path: \(path)"
    if includeSelection, let selection, !selection.isEmpty {
      if let lines { value += "\nLines: \(lines.lowerBound)-\(lines.upperBound)" }
      value += "\n\n" + selection
    }
    return value
  }
}
