// 模糊子序列打分：查询的每个字符按顺序出现在字段里即算命中，连续命中与词首命中加分，跳过的字符扣分。
import Foundation

enum ToolFuzzyScorer {
  static let matchScore = 16
  static let boundaryBonus = 8
  /// 第一个字符落在词首时加倍，前缀与「首字母」输入因此明显占优。
  static let firstCharacterMultiplier = 2
  static let consecutiveBonus = 8
  static let gapStartPenalty = 3
  static let gapExtensionPenalty = 1

  /// 理想得分：从词首开始、全部连续命中。
  static func idealScore(length: Int) -> Int {
    length * matchScore + boundaryBonus * firstCharacterMultiplier + max(0, length - 1) * consecutiveBonus
  }

  /// 查询是字段的子序列时返回 0...1 的匹配质量（相对理想得分）；不是子序列或过于零散时返回 nil。
  static func quality(of query: [Unicode.Scalar], in form: ToolSearchForm) -> Double? {
    guard let score = score(query, in: form), score > 0 else { return nil }
    return min(1, Double(score) / Double(idealScore(length: query.count)))
  }

  /// 最优对齐的得分；查询不是子序列时为 nil。
  /// 先线性预检子序列，绝大多数字段在这里就被排除；通过的再做 O(查询长 × 字段长) 的动态规划，
  /// 避免贪心最左匹配错过更好的对齐（例如「hh」应落在两个音节首字母上，而不是第一个出现的 h）。
  static func score(_ query: [Unicode.Scalar], in form: ToolSearchForm) -> Int? {
    let haystack = form.scalars
    let count = haystack.count
    guard !query.isEmpty, query.count <= count, isSubsequence(query, of: haystack) else { return nil }
    let unreachable = Int.min / 4
    // previous[j]：查询前 i 个字符已匹配、且第 i 个字符落在 j 时的最高分。
    var previous = [Int](repeating: unreachable, count: count)
    for index in 0..<count where haystack[index] == query[0] {
      previous[index] = matchScore + bonus(form, index) * firstCharacterMultiplier
    }
    for queryIndex in 1..<query.count {
      var current = [Int](repeating: unreachable, count: count)
      // gapBest：上一字符落在 k ≤ j-2、中间跳过 j-k-1 个字符时扣分后的最好成绩，随 j 递推。
      var gapBest = unreachable
      let target = query[queryIndex]
      for index in 1..<count {
        if index >= 2 {
          gapBest = max(gapBest - gapExtensionPenalty, previous[index - 2] - gapStartPenalty)
        }
        guard haystack[index] == target else { continue }
        var best = unreachable
        if previous[index - 1] > unreachable {
          best = previous[index - 1] + max(consecutiveBonus, bonus(form, index))
        }
        if gapBest > unreachable / 2 {
          best = max(best, gapBest + bonus(form, index))
        }
        if best > unreachable / 2 { current[index] = best + matchScore }
      }
      previous = current
    }
    let best = previous.max() ?? unreachable
    return best > unreachable / 2 ? best : nil
  }

  /// 词首加分。
  private static func bonus(_ form: ToolSearchForm, _ index: Int) -> Int {
    form.boundaries[index] ? boundaryBonus : 0
  }

  /// 线性子序列预检。
  private static func isSubsequence(_ query: [Unicode.Scalar], of haystack: [Unicode.Scalar]) -> Bool {
    var next = 0
    for scalar in haystack where scalar == query[next] {
      next += 1
      if next == query.count { return true }
    }
    return false
  }
}
