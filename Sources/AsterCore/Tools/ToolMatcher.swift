// 工具搜索与内容匹配：关键词（含拼音）找工具，内容规则（正则 / 任意文本 / 文件）推荐工具。
import Foundation

/// 纯函数匹配器，可在任意线程调用（内部缓存有锁）。调用方负责在后台线程调用并按发起身份回写结果。
public enum ToolMatcher {
  /// 内容匹配时整体输入的长度上限（UTF-16 单元）；超过直接不跑文本规则，文件规则不受影响。
  public static let maximumContentLength = 1_048_576
  /// 查询拆出的词超过这个数（通常是粘贴了一段正文）就不做关键词搜索，交给内容匹配。
  static let maximumQueryTokens = 16

  // MARK: 打分权重
  // 搜索分数 = 100 × 匹配质量（0...1，按字段权重折算）+ 完全/前缀命中加分 + 使用频次加分（≤ 40）。
  // 加分档位保证：标题完全命中 > 标题前缀命中 > 其余命中，常用程度只在同档内调整顺序；
  // 关键词完全命中略低于标题前缀，常用时可以超过它。

  static let titleWeight = 1.0
  static let keywordWeight = 0.9
  static let pluginNameWeight = 0.75
  static let subtitleWeight = 0.6
  /// 同一字段，直接命中略优于拼音命中。
  static let pinyinWeight = 0.95
  static let exactTitleBonus = 100.0
  static let titlePrefixBonus = 50.0
  static let keywordExactBonus = 40.0
  static let maximumFrecencyBonus = 40.0
  /// 内容匹配按规则等级分档，每档宽度远大于频次加分，保证 regex 命中永远排在 text 之前。
  static let contentTierWidth = 1_000.0

  /// 关键词搜索：对标题、关键词、插件名、副标题做大小写与变音无关的模糊子序列匹配，中文同时比对拼音全拼与首字母。
  /// 查询按空白拆词，每个词都要在某个字段命中。空查询按使用频次返回最常用的工具。
  /// 同分时保持 `entries` 的原有顺序，所以调用方应给出稳定的条目顺序。
  public static func search(
    _ query: String,
    entries: [ToolCatalogEntry],
    usage: ToolUsageStats,
    now: Date,
    limit: Int
  ) -> [ToolMatch] {
    guard limit > 0 else { return [] }
    let tokens = ToolSearchNormalizer.queryTokens(query)
    var scored: [(match: ToolMatch, index: Int)] = []
    if tokens.isEmpty {
      for (index, entry) in entries.enumerated() {
        scored.append((ToolMatch(entry: entry, reason: .search, score: usage.frecency(entry.id, now: now)), index))
      }
      return ranked(scored, limit: limit)
    }
    guard tokens.count <= maximumQueryTokens else { return [] }
    let compactQuery = String(String.UnicodeScalarView(tokens.joined()))
    for (index, entry) in entries.enumerated() {
      guard let quality = searchQuality(entry, tokens: tokens, compactQuery: compactQuery) else { continue }
      let score = quality + frecencyBonus(usage.frecency(entry.id, now: now))
      scored.append((ToolMatch(entry: entry, reason: .search, score: score), index))
    }
    return ranked(scored, limit: limit)
  }

  /// 匹配质量（0...100）加完全/前缀命中加分；任何一个查询词在所有字段都没命中时为 nil。
  static func searchQuality(_ entry: ToolCatalogEntry, tokens: [[Unicode.Scalar]], compactQuery: String) -> Double? {
    let feature = entry.feature
    let title = ToolSearchNormalizer.text(for: feature.title)
    let keywords = feature.keywords.map(ToolSearchNormalizer.text(for:))
    var fields: [(text: ToolSearchText, weight: Double)] = [(title, titleWeight)]
    fields += keywords.map { ($0, keywordWeight) }
    fields.append((ToolSearchNormalizer.text(for: entry.pluginName), pluginNameWeight))
    if let subtitle = feature.subtitle, !subtitle.isEmpty {
      fields.append((ToolSearchNormalizer.text(for: subtitle), subtitleWeight))
    }
    var total = 0.0
    for token in tokens {
      var best = 0.0
      for field in fields {
        if let quality = ToolFuzzyScorer.quality(of: token, in: field.text.original) {
          best = max(best, quality * field.weight)
        }
        if let pinyin = field.text.pinyin, let quality = ToolFuzzyScorer.quality(of: token, in: pinyin) {
          best = max(best, quality * field.weight * pinyinWeight)
        }
      }
      guard best > 0 else { return nil }
      total += best
    }
    return 100 * total / Double(tokens.count) + exactnessBonus(title: title, keywords: keywords, query: compactQuery)
  }

  /// 整个查询（去掉空白）与标题原文、拼音全拼、首字母完全相同或是其前缀，或与某个关键词完全相同时的加分。
  static func exactnessBonus(title: ToolSearchText, keywords: [ToolSearchText], query: String) -> Double {
    let titleForms = [title.original.compact, title.pinyin?.compact, title.initials].compactMap { $0 }
    if titleForms.contains(query) { return exactTitleBonus }
    if titleForms.contains(where: { $0.hasPrefix(query) }) { return titlePrefixBonus }
    if keywords.contains(where: { $0.original.compact == query || $0.pinyin?.compact == query }) {
      return keywordExactBonus
    }
    return 0
  }

  /// 使用频次的加分：对数增长并封顶，常用工具靠前但不压过更准确的命中。
  static func frecencyBonus(_ frecency: Double) -> Double {
    frecency > 0 ? min(maximumFrecencyBonus, 10 * log2(1 + frecency)) : 0
  }

  /// 分数高的在前；同分保持条目原有顺序（稳定排序），避免刷新时行序抖动。
  static func ranked(_ scored: [(match: ToolMatch, index: Int)], limit: Int) -> [ToolMatch] {
    scored
      .sorted { lhs, rhs in
        lhs.match.score != rhs.match.score ? lhs.match.score > rhs.match.score : lhs.index < rhs.index
      }
      .prefix(limit)
      .map(\.match)
  }
}
