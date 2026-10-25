// 根据恢复的原生标志与历史统计决定预览。
import Foundation

/// 未选择候选时的内联预览门槛。选择状态由终端控制器维护。
public enum CompletionPresentation {
  public static func leaderIsClear(_ candidates: [AutocompleteCandidate]) -> Bool {
    guard let first = candidates.first else { return false }
    if let explicit = first.clearLeader { return explicit }
    let history = first.kind == .learnedCommand
    let rivals = candidates.dropFirst().filter { ($0.kind == .learnedCommand) == history }
    if first.kind == .learnedCommand {
      guard let second = rivals.first else { return true }
      guard let date = first.historyUsage?.lastUsedAt else { return false }
      return first.score >= second.score + 0.5
        && rivals.allSatisfy { ($0.historyUsage?.lastUsedAt ?? .distantFuture) <= date }
    }
    guard let lead = first.historyScore else { return false }
    let scores = rivals.compactMap(\.historyScore)
    guard let runnerUp = scores.max() else { return true }
    return lead >= runnerUp * 1.5
  }
}
