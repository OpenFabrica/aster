// 内容匹配：regex / text / files 规则、长度上限、等级排序、内置工具二次确认与正则时间预算。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolMatcherContent")
struct ToolMatcherContentTests {
  typealias Fixture = ToolMatcherFixture

  /// 对文本输入做内容匹配，返回功能代码。
  private func codes(
    _ text: String?,
    files: [String] = [],
    _ entries: [ToolCatalogEntry],
    usage: ToolUsageStats = ToolUsageStats(),
    isDirectory: (String) -> Bool = { _ in false }
  ) -> [String] {
    ToolMatcher.contentMatches(
      for: ToolInput(text: text, files: files), entries: entries, usage: usage, now: Fixture.now, limit: 50,
      isDirectory: isDirectory
    ).map(\.entry.feature.code)
  }

  /// regex 规则按长度范围过滤，缺省最多 10,000 个字符。
  @Test func regexRuleRespectsLengths() {
    let digits = Fixture.entry(code: "d", title: "D", match: [.regex(ToolRegexRule(pattern: "^\\d+$", minLength: 3, maxLength: 5))])
    #expect(codes("123", [digits]) == ["d"])
    #expect(codes("12345", [digits]) == ["d"])
    #expect(codes("12", [digits]).isEmpty)
    #expect(codes("123456", [digits]).isEmpty)
    #expect(codes("12a", [digits]).isEmpty)
    let any = Fixture.entry(code: "x", title: "X", match: [.regex(ToolRegexRule(pattern: "x"))])
    #expect(codes(String(repeating: "x", count: 10_000), [any]) == ["x"])
    #expect(codes(String(repeating: "x", count: 10_001), [any]).isEmpty)
  }

  /// text 规则匹配任意文本，exclude 命中时排除（exclude 允许空匹配）。
  @Test func textRuleWithExclude() {
    let entry = Fixture.entry(code: "t", title: "T", match: [.text(ToolTextRule(exclude: "^\\s*$|secret"))])
    #expect(codes("hello", [entry]) == ["t"])
    #expect(codes("   ", [entry]).isEmpty)
    #expect(codes("my secret", [entry]).isEmpty)
    #expect(codes("", [entry]).isEmpty)
    #expect(codes(nil, [entry]).isEmpty)
  }

  /// regex 命中永远排在 text 之前，即使 text 功能用得多得多；同一功能取等级最高的规则与它的标签。
  @Test func regexOutranksTextAndBestRuleWins() {
    let text = Fixture.entry(code: "text", title: "Text", match: [.text(ToolTextRule(label: "任意"))])
    let both = Fixture.entry(
      code: "both", title: "Both",
      match: [.text(ToolTextRule(label: "文本")), .regex(ToolRegexRule(label: "数字", pattern: "\\d"))])
    let usage = Fixture.usage([text.id: 100_000])
    let matches = ToolMatcher.contentMatches(
      for: ToolInput(text: "abc 1"), entries: [text, both], usage: usage, now: Fixture.now, limit: 10)
    #expect(matches.map(\.entry.feature.code) == ["both", "text"])
    #expect(matches.first?.reason == .content(ruleIndex: 1, label: "数字"))
    #expect(codes("abc", [text, both]) == ["text", "both"])
  }

  /// 只有 text 规则命中才算「只认是文字」；regex、files 命中、关键词搜索与越界下标都不算。
  @Test func textRuleMatchesAreFlagged() {
    let matches = ToolMatcher.contentMatches(
      for: ToolInput(text: "1700000000"), entries: Fixture.builtinEntries(), usage: ToolUsageStats(), now: Fixture.now,
      limit: 10)
    #expect(matches.map(\.entry.feature.code) == ["timestamp", "hash"])
    #expect(matches.map(\.isTextRuleMatch) == [false, true])
    let hash = matches[1].entry
    #expect(!ToolMatch(entry: hash, reason: .search, score: 1).isTextRuleMatch)
    #expect(!ToolMatch(entry: hash, reason: .content(ruleIndex: 9, label: nil), score: 1).isTextRuleMatch)
    let files = Fixture.entry(code: "f", title: "F", match: [.files(ToolFilesRule())])
    #expect(!ToolMatch(entry: files, reason: .content(ruleIndex: 0, label: nil), score: 1).isTextRuleMatch)
  }

  /// 超过全局上限（1 MiB UTF-16）的文本不跑文本规则，文件规则不受影响。
  @Test func globalLengthLimitSkipsTextRules() {
    let text = Fixture.entry(code: "t", title: "T", match: [.text(ToolTextRule(maxLength: 1_048_576))])
    let files = Fixture.entry(code: "f", title: "F", match: [.files(ToolFilesRule())])
    let huge = String(repeating: "a", count: ToolMatcher.maximumContentLength + 1)
    #expect(codes(huge, files: ["/tmp/a.txt"], [text, files]) == ["f"])
  }

  /// files 规则：扩展名（大小写无关）、文件名正则、类型、数量，所有文件都要满足；目录判断每个路径只问一次。
  @Test func filesRules() {
    let images = Fixture.entry(code: "img", title: "I", match: [.files(ToolFilesRule(fileType: .file, extensions: ["png", "jpg"]))])
    let docker = Fixture.entry(code: "dock", title: "D", match: [.files(ToolFilesRule(pattern: "^Dockerfile$"))])
    let folders = Fixture.entry(code: "dir", title: "R", match: [.files(ToolFilesRule(fileType: .directory, maxCount: 2))])
    let entries = [images, docker, folders]
    var asked: [String: Int] = [:]
    let isDirectory = { (path: String) -> Bool in
      asked[path, default: 0] += 1
      return path.hasSuffix("/")
    }
    #expect(codes(nil, files: ["/a/x.PNG", "/b/y.jpg"], entries, isDirectory: isDirectory) == ["img"])
    #expect(codes(nil, files: ["/a/x.png", "/b/y.gif"], entries, isDirectory: isDirectory).isEmpty)
    #expect(codes(nil, files: ["/repo/Dockerfile"], entries, isDirectory: isDirectory) == ["dock"])
    #expect(codes(nil, files: ["/p/", "/q/"], entries, isDirectory: isDirectory) == ["dir"])
    #expect(codes(nil, files: ["/s/", "/t/", "/u/"], entries, isDirectory: isDirectory).isEmpty)
    #expect(asked.values.allSatisfy { $0 == 1 })
  }

  /// 内置工具：正则粗筛之后还要内容确认，普通单词不会被推荐成 Base64，越界端口与不存在的日期也不会。
  @Test func builtinMatchesAreConfirmed() {
    let entries = Fixture.builtinEntries()
    #expect(codes("aGVsbG8gd29ybGQ=", entries) == ["base64", "hash"])
    #expect(codes("password", entries) == ["hash"])
    #expect(codes("1700000000", entries) == ["timestamp", "hash"])
    #expect(codes("2024-02-29 08:00", entries) == ["timestamp", "hash"])
    #expect(codes("2023-02-29", entries) == ["hash"])
    #expect(codes(":8080", entries) == ["ports", "hash"])
    #expect(codes("70000", entries) == ["hash"])
    #expect(codes("https://example.com/a?b=c", entries) == ["url", "hash"])
    #expect(codes("name=a%20b", entries) == ["url", "hash"])
    #expect(codes("{\"a\": 1}", entries) == ["json", "hash"])
    let label = ToolMatcher.contentMatches(
      for: ToolInput(text: "1700000000"), entries: entries, usage: ToolUsageStats(), now: Fixture.now, limit: 1
    ).first?.reason
    #expect(label == .content(ruleIndex: 0, label: L("转成日期")))
  }

  /// 灾难性回溯的正则在时间预算内放弃，按没命中处理。
  @Test func catastrophicRegexIsBounded() throws {
    let evil = Fixture.entry(code: "evil", title: "E", match: [.regex(ToolRegexRule(pattern: "^(a+)+$"))])
    let input = String(repeating: "a", count: 40) + "b"
    let clock = ContinuousClock()
    let elapsed = clock.measure { #expect(codes(input, [evil]).isEmpty) }
    #expect(elapsed < .seconds(2))
    let expression = try #require(ToolRegex.compiled("^(a+)+$"))
    #expect(ToolRegex.firstMatch(expression, in: input, allowsEmptyMatch: false, budget: .milliseconds(20)) == .timedOut)
  }

  /// 代码直接构造、没经过校验的可空正则也不会靠空匹配命中任意输入。
  @Test func emptyMatchesNeverCount() {
    let entry = Fixture.entry(code: "a", title: "A", match: [.regex(ToolRegexRule(pattern: "a*"))])
    #expect(codes("bbb", [entry]).isEmpty)
    #expect(codes("baa", [entry]) == ["a"])
  }

  /// 无效正则（未经校验构造）只当作不命中，不影响其他功能。
  @Test func invalidPatternsNeverMatch() {
    let broken = Fixture.entry(code: "broken", title: "B", match: [.regex(ToolRegexRule(pattern: "("))])
    let fine = Fixture.entry(code: "fine", title: "F", match: [.regex(ToolRegexRule(pattern: "x"))])
    #expect(codes("x(", [broken, fine]) == ["fine"])
  }
}
