// 判定首个候选是否「明显领先」：多个候选时只有明显领先的首项才画 ghost。
import Foundation

/// 整行学习历史的使用统计，供判定首项是否明显领先。
public struct AutocompleteHistoryUsage: Equatable, Sendable {
  public let useCount: Int
  public let lastUsedAt: Date

  public init(useCount: Int, lastUsedAt: Date) {
    self.useCount = useCount
    self.lastUsedAt = lastUsedAt
  }

  /// 从学习库建议取统计；建议没带最后使用时间时返回 nil。
  public init?(_ suggestion: AutocompleteLearnedSuggestion) {
    guard let lastUsedAt = suggestion.lastUsedAt else { return nil }
    self.init(useCount: suggestion.useCount, lastUsedAt: lastUsedAt)
  }
}

/// Otty 的 `clear_leader` 规则，换算到 Aster 的统一分制。
///
/// Otty 引擎分两路标记首项（反编译 Otty 1.5.4 所得）：
/// - 整行历史：首条分数 ≥ 次条 + 0.5，且它是最近用过的一条。Otty 的历史分数约等于
///   衰减后的使用次数，+0.5 就是「至少多用一次」。Aster 直接用学习库的使用次数与
///   最后使用时间表达同一含义：首条比其它匹配的历史用得更多，并且最近用过。
/// - 其它候选：首项分数 ≥ 次项的 1.5 倍。Otty 的分数从 0 起算；Aster 的分数含按类型
///   区分的基础权重（`AutocompleteRelevance.baseWeight`），比例只对去掉基础权重后的
///   「匹配度 + 使用加成」才有意义，所以先减去再比。
///
/// 两路互不比较：首项是历史时只看其它历史，首项是别的候选时只看其它非历史候选。
public enum AutocompleteInlineLead {
  /// 非历史首项的相关分至少是次项的这么多倍，才算明显领先。
  public static let relevanceRatio: Double = 1.5

  /// 首项是否明显领先。只有一个候选时恒为 true；没有候选时为 false。
  public static func leaderIsClear(_ candidates: [AutocompleteCandidate]) -> Bool {
    guard let leader = candidates.first else { return false }
    let rest = candidates.dropFirst()
    if isHistoryLine(leader) {
      let rivals = rest.filter(isHistoryLine)
      guard !rivals.isEmpty else { return true }
      // 缺统计的历史无法比较，按不领先处理，保持保守。
      guard let usage = leader.historyUsage else { return false }
      return rivals.allSatisfy { rival in
        guard let other = rival.historyUsage else { return false }
        return usage.useCount > other.useCount && usage.lastUsedAt >= other.lastUsedAt
      }
    }
    guard let runnerUp = rest.first(where: { !isHistoryLine($0) }) else { return true }
    let lead = relevance(of: leader)
    guard lead > 0 else { return false }
    return lead >= relevanceRatio * max(relevance(of: runnerUp), 0)
  }

  /// 按目录学来的整行命令，对应 Otty 的整行历史来源。
  public static func isHistoryLine(_ candidate: AutocompleteCandidate) -> Bool {
    candidate.kind == .learnedCommand && candidate.replacement == .fullLine
  }

  /// 去掉按类型区分的基础权重后的分数，即匹配度、频率与上下文加成之和。
  static func relevance(of candidate: AutocompleteCandidate) -> Double {
    candidate.score - AutocompleteRelevance.baseWeight(for: candidate.kind)
  }
}
