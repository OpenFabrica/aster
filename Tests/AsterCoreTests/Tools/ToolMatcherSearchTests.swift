// 关键词搜索：大小写 / 变音 / 全角无关的模糊子序列匹配，拼音全拼与首字母，排序档位、频次与稳定排序。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolMatcherSearch")
struct ToolMatcherSearchTests {
  typealias Fixture = ToolMatcherFixture

  /// 大小写、变音符号与全角字符都不影响命中。
  @Test(arguments: ["cafe", "CAFÉ", "ｃａｆｅ", "résumé", "cfrs"])
  func foldsCaseDiacriticsAndWidth(query: String) {
    let entries = [Fixture.entry(code: "c", title: "Café Résumé")]
    #expect(Fixture.searchCodes(query, entries) == ["c"])
  }

  /// 查询是字段的子序列才算命中。
  @Test func fuzzySubsequence() {
    let entries = [Fixture.entry(code: "fmt", title: "JSON Formatter")]
    #expect(Fixture.searchCodes("jsfmt", entries) == ["fmt"])
    #expect(Fixture.searchCodes("fmtjs", entries).isEmpty)
    #expect(Fixture.searchCodes("xyz", entries).isEmpty)
  }

  /// 中文标题可以用汉字、拼音全拼、首字母或二者混合搜到，繁体同样适用。
  @Test(arguments: ["时间", "转换", "shijianchuo", "shijian", "sjc", "sjczh", "shijc", "zhuanhuan"])
  func matchesChineseByPinyin(query: String) {
    let entries = [Fixture.entry(code: "ts", title: "时间戳转换"), Fixture.entry(code: "other", title: "Other")]
    #expect(Fixture.searchCodes(query, entries) == ["ts"])
  }

  /// 繁体标题也能用拼音搜到。
  @Test func matchesTraditionalChineseByPinyin() {
    #expect(Fixture.searchCodes("sjc", [Fixture.entry(code: "ts", title: "時間戳轉換")]) == ["ts"])
  }

  /// 关键词、插件名、副标题都参与匹配。
  @Test func searchesKeywordsPluginNameAndSubtitle() {
    let entries = [
      Fixture.entry(code: "kw", title: "Alpha", keywords: ["timestamp"]),
      Fixture.entry(plugin: "com.example.jwt", name: "JWT Toolkit", code: "name", title: "Beta"),
      Fixture.entry(code: "sub", title: "Gamma", subtitle: "header / payload"),
    ]
    #expect(Fixture.searchCodes("timest", entries) == ["kw"])
    #expect(Fixture.searchCodes("toolkit", entries) == ["name"])
    #expect(Fixture.searchCodes("payload", entries) == ["sub"])
    #expect(Fixture.searchCodes("时间戳", [Fixture.entry(code: "zh", title: "Unix", keywords: ["时间戳"])]) == ["zh"])
  }

  /// 排序档位：标题完全命中 > 标题前缀 > 关键词完全命中 > 其余模糊命中。
  @Test func ranksExactThenPrefixThenKeywordThenFuzzy() {
    let entries = [
      Fixture.entry(code: "fuzzy", title: "Jason's Notes"),
      Fixture.entry(code: "keyword", title: "Pretty Printer", keywords: ["json"]),
      Fixture.entry(code: "prefix", title: "JSON 格式化"),
      Fixture.entry(code: "exact", title: "JSON"),
    ]
    #expect(Fixture.searchCodes("json", entries) == ["exact", "prefix", "keyword", "fuzzy"])
  }

  /// 拼音首字母完全相同算标题完全命中，排在只是前缀命中的条目前面。
  @Test func pinyinInitialsCountAsExactTitle() {
    let entries = [Fixture.entry(code: "longer", title: "时间戳转换器"), Fixture.entry(code: "exact", title: "时间戳转换")]
    #expect(Fixture.searchCodes("sjczh", entries) == ["exact", "longer"])
  }

  /// 使用频次在同一档内调整顺序，但不能把模糊命中提到标题前缀命中之前。
  @Test func frecencyReordersWithinTierOnly() {
    let entries = [
      Fixture.entry(code: "a", title: "Format A"),
      Fixture.entry(code: "b", title: "Format B"),
      Fixture.entry(code: "c", title: "Reformat"),
    ]
    let id = { (code: String) in ToolCatalogEntry.makeID(pluginID: "com.example.tool", code: code) }
    #expect(Fixture.searchCodes("format", entries) == ["a", "b", "c"])
    #expect(Fixture.searchCodes("format", entries, usage: Fixture.usage([id("b"): 3])) == ["b", "a", "c"])
    #expect(Fixture.searchCodes("format", entries, usage: Fixture.usage([id("c"): 10_000])).last == "c")
  }

  /// 同分时保持条目原有顺序。
  @Test func tiesKeepEntryOrder() {
    let first = Fixture.entry(plugin: "com.example.b", code: "x", title: "Same Title")
    let second = Fixture.entry(plugin: "com.example.a", code: "x", title: "Same Title")
    let forward = ToolMatcher.search("same", entries: [first, second], usage: ToolUsageStats(), now: Fixture.now, limit: 5)
    let backward = ToolMatcher.search("same", entries: [second, first], usage: ToolUsageStats(), now: Fixture.now, limit: 5)
    #expect(forward.map(\.entry.pluginID) == ["com.example.b", "com.example.a"])
    #expect(backward.map(\.entry.pluginID) == ["com.example.a", "com.example.b"])
    #expect(forward.allSatisfy { $0.reason == .search })
  }

  /// 空查询按使用频次返回，没用过的保持原顺序；结果受 limit 限制。
  @Test func emptyQueryReturnsMostUsed() {
    let entries = (0..<5).map { Fixture.entry(code: "f\($0)", title: "Tool \($0)") }
    let usage = Fixture.usage([entries[3].id: 5, entries[1].id: 2])
    #expect(Fixture.searchCodes("  ", entries, usage: usage, limit: 4) == ["f3", "f1", "f0", "f2"])
  }

  /// 多个词各自都要命中，顺序无关；任何一个词没命中就排除。
  @Test func everyTokenMustMatch() {
    let entries = [Fixture.entry(code: "fmt", title: "JSON 格式化", keywords: ["pretty"])]
    #expect(Fixture.searchCodes("json 格式", entries) == ["fmt"])
    #expect(Fixture.searchCodes("geshi json", entries) == ["fmt"])
    #expect(Fixture.searchCodes("pretty json", entries) == ["fmt"])
    #expect(Fixture.searchCodes("json xyz", entries).isEmpty)
  }

  /// limit ≤ 0 或查询词过多（粘贴了一段正文）时直接返回空。
  @Test func degenerateQueries() {
    let entries = [Fixture.entry(code: "a", title: "a b c d e f g h i j k l m n o p q")]
    #expect(Fixture.searchCodes("a", entries, limit: 0).isEmpty)
    #expect(Fixture.searchCodes("a b c d e f g h i j k l m n o p", entries) == ["a"])
    #expect(Fixture.searchCodes("a b c d e f g h i j k l m n o p q", entries).isEmpty)
  }
}
