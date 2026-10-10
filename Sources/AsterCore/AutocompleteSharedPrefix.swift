// 多条同样可能的历史整行互相冲突时，只预览它们共同的下一个词。
import Foundation

/// Otty 的规则：ghost 绝不是「几个候选里随便挑一个」。多条整行历史分数接近、谁也不
/// 明显领先时，不预览任何一条，但它们共同的下一个词是确定的，可以先画出来。
/// 规格 token 候选（子命令、选项）本身不参与：没有历史时 `git ch` 的 checkout / cherry-pick 继续只进面板。
public enum AutocompleteSharedPrefix {
  /// 参与共同前缀计算的候选类型：都是按目录学来的整行命令。
  static let historyLineKinds: Set<AutocompleteCandidateKind> = [.learnedCommand, .readmeCommand, .snippet]
  /// 与首项分差在此以内视为「同样可能」，与跨来源归并的平局阈值一致。
  public static let scoreMargin: Double = 15
  /// 最多看前几条，对应候选面板的可见行数。
  public static let candidateLimit = 8

  /// 返回应追加到 `line` 之后的共同续写（以空格结尾的完整词），没有则 nil。
  /// 需要至少两条同样可能的整行历史；首项要么就是其中一条，要么是一个 token 候选
  /// （如槽位学习给出的 `commit`）且正好等于这个共同词——否则保持既有保守行为。
  public static func ghost(candidates: [AutocompleteCandidate], line: String) -> String? {
    guard let first = candidates.first else { return nil }
    let window = candidates.prefix(candidateLimit)
    guard let topLine = window.first(where: { isHistoryLine($0) }) else { return nil }
    let group = window.filter { isHistoryLine($0) && $0.score >= topLine.score - scoreMargin }
    guard group.count >= 2 else { return nil }
    let suffixes = group.compactMap { $0.appendableSuffix(from: line) }
    guard suffixes.count == group.count, let shared = sharedContinuation(of: suffixes) else { return nil }
    if isHistoryLine(first) { return shared }
    // 首项是单个 token：只有它就是那个共同词时才预览，避免 ghost 与面板首项说法不一。
    guard case .currentToken = first.replacement, let tokenSuffix = first.appendableSuffix(from: line),
      tokenSuffix + " " == shared
    else { return nil }
    return shared
  }

  /// 按目录学来的整行命令才参与共同前缀计算。
  static func isHistoryLine(_ candidate: AutocompleteCandidate) -> Bool {
    historyLineKinds.contains(candidate.kind) && candidate.replacement == .fullLine
  }

  /// 多段后缀的最长公共前缀，修剪到最后一个完整词（含其后的空格）。
  /// 公共前缀停在半个词里、且并非所有候选在那里都正好结束一个词时返回 nil。
  static func sharedContinuation(of suffixes: [String]) -> String? {
    guard let shortest = suffixes.min(by: { $0.count < $1.count }), !shortest.isEmpty else { return nil }
    var common = Array(shortest)
    for suffix in suffixes {
      let characters = Array(suffix)
      var length = 0
      while length < common.count, length < characters.count, common[length] == characters[length] { length += 1 }
      common.removeSubrange(length...)
      if common.isEmpty { return nil }
    }
    if let lastSpace = common.lastIndex(where: \.isWhitespace) {
      let trimmed = String(common[...lastSpace])
      return trimmed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : trimmed
    }
    // 公共部分没有空格：只有每条候选在这里都正好结束一个词（后面是空格或整条结束）才算完整。
    let wordComplete = suffixes.allSatisfy { suffix in
      let characters = Array(suffix)
      return characters.count == common.count || characters[common.count].isWhitespace
    }
    return wordComplete ? String(common) + " " : nil
  }
}
