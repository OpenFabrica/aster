// 原版学习忽略模式仅包含 * 和 ?，不使用平台 glob 的扩展语法。
import Foundation

public enum CompletionIgnorePattern {
  /// 双方先转小写；? 匹配一个 Unicode scalar，* 匹配零个或多个 scalar。
  public static func matches(command: String, pattern: String) -> Bool {
    let input = Array(command.lowercased().unicodeScalars)
    let glob = Array(pattern.lowercased().unicodeScalars)
    var inputIndex = 0
    var patternIndex = 0
    var star: Int?
    var retryInput = 0
    while inputIndex < input.count {
      if patternIndex < glob.count && (glob[patternIndex] == "?" || glob[patternIndex] == input[inputIndex]) {
        inputIndex += 1
        patternIndex += 1
      } else if patternIndex < glob.count && glob[patternIndex] == "*" {
        star = patternIndex
        patternIndex += 1
        retryInput = inputIndex
      } else if let star {
        retryInput += 1
        inputIndex = retryInput
        patternIndex = star + 1
      } else {
        return false
      }
    }
    while patternIndex < glob.count && glob[patternIndex] == "*" { patternIndex += 1 }
    return patternIndex == glob.count
  }
}
