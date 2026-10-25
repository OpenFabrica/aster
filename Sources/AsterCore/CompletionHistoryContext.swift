// 为词频记录、失败清理和查询使用相同的命令上下文。
import Foundation

/// 上下文由命令及已识别的子命令前缀组成；startIndex 是剩余参数的起点。
public struct CompletionHistoryContext: Equatable, Sendable {
  public let context: String
  public let startIndex: Int

  public static func resolve(tokens: [String], database: AutocompleteSpecDatabase) -> Self {
    guard let root = tokens.first else { return Self(context: "", startIndex: 0) }
    var parts = [root]
    var index = 1
    var specification = database.command(named: root)
    while index < tokens.count, let child = specification?.subcommand(named: tokens[index]) {
      parts.append(tokens[index])
      specification = child
      index += 1
    }
    return Self(context: parts.joined(separator: " "), startIndex: index)
  }

  /// 首词通常使用全局上下文；相对可执行文件按执行目录隔离。
  public static func commandContext(command: String, directory: String) -> String {
    if !directory.isEmpty && (command.hasPrefix("./") || command.hasPrefix("../")) {
      return "\u{0}cwd:" + directory
    }
    return ""
  }

  /// 与原生运行期 bonus 集合的 context + TAB + argument 键保持一致。
  public static func key(context: String, argument: String) -> String {
    context + "\t" + argument
  }
}
