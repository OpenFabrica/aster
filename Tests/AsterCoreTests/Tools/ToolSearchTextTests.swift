// 搜索文本归一化与模糊打分：词首标记、拼音全拼与首字母、缓存一致性、打分偏好。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolSearchText")
struct ToolSearchTextTests {
  /// 词首：开头、空白之后、每个汉字、字母数字切换、驼峰、标点之后；空白本身被去掉。
  @Test func boundariesAreMarked() {
    let mixed = ToolSearchNormalizer.form(of: "JSON 格式化")
    #expect(mixed.compact == "json格式化")
    #expect(mixed.boundaries == [true, false, false, false, true, true, true])
    let camel = ToolSearchNormalizer.form(of: "openURL v2.x")
    #expect(camel.compact == "openurlv2.x")
    #expect(camel.boundaries == [true, false, false, false, true, false, false, true, true, false, true])
  }

  /// 拼音全拼与首字母：音节首字母是词首，非汉字单词也贡献首字母。
  @Test func pinyinFormsAndInitials() throws {
    let text = ToolSearchNormalizer.make("时间戳转换")
    let pinyin = try #require(text.pinyin)
    #expect(pinyin.compact == "shijianchuozhuanhuan")
    #expect(text.initials == "sjczh")
    #expect(ToolSearchNormalizer.make("Base64 编解码").initials == "bbjm")
    #expect(ToolSearchNormalizer.make("UUID / 随机串").initials == "usjc")
    #expect(ToolSearchNormalizer.make("Plain").pinyin == nil)
  }

  /// 缓存结果与直接计算一致，并发读取安全。
  @Test func cacheMatchesDirectComputation() async {
    let strings = (0..<64).map { "工具 \($0) Tool" }
    await withTaskGroup(of: Bool.self) { group in
      for string in strings {
        group.addTask { ToolSearchNormalizer.text(for: string) == ToolSearchNormalizer.make(string) }
      }
      for await same in group { #expect(same) }
    }
  }

  /// 打分偏好：连续且从词首开始的命中优于零散命中；不是子序列时为 nil。
  @Test func scorerPrefersContiguousBoundaryMatches() throws {
    let form = ToolSearchNormalizer.form(of: "JSON Formatter")
    let prefix = try #require(ToolFuzzyScorer.quality(of: Array("json".unicodeScalars), in: form))
    let initials = try #require(ToolFuzzyScorer.quality(of: Array("jf".unicodeScalars), in: form))
    let scattered = try #require(ToolFuzzyScorer.quality(of: Array("soter".unicodeScalars), in: form))
    #expect(prefix == 1)
    #expect(initials > scattered)
    #expect(ToolFuzzyScorer.quality(of: Array("xyz".unicodeScalars), in: form) == nil)
  }

  /// 动态规划取最优对齐：「zh」的 h 既可紧跟 z 连续命中，也可落在后面「huan」的词首，连续命中得分更高。
  @Test func scorerFindsBestAlignment() throws {
    let form = try #require(ToolSearchNormalizer.make("时间戳转换").pinyin)
    let score = try #require(ToolFuzzyScorer.score(Array("zh".unicodeScalars), in: form))
    // z 在「zhuan」词首，h 紧跟其后：词首加倍 + 连续加分。
    #expect(score == 2 * ToolFuzzyScorer.matchScore + 2 * ToolFuzzyScorer.boundaryBonus + ToolFuzzyScorer.consecutiveBonus)
  }
}
