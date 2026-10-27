// 脚本工具 list 输出的解析：字段、200 项上限、title/subtitle 截断、value 与 title 的严格校验、坏 JSON 与输出大小。
import Foundation
import Testing

@testable import AsterCore

@Suite("ScriptToolProtocolList")
struct ScriptToolProtocolListTests {
  /// 把条目包成 `{"items": [...]}` 的 JSON 数据。
  private func output(_ items: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["items": items])
  }

  /// 重复同一个字符，用来构造恰好踩在上限上的长度。
  private func run(_ character: Character, _ count: Int) -> String {
    String(repeating: character, count: count)
  }

  /// 解析并返回抛出的 `ScriptToolError`；成功解析时返回 nil。
  private func failure(_ data: Data) -> ScriptToolError? {
    do {
      _ = try ScriptToolProtocol.parseList(data)
      return nil
    } catch {
      return error as? ScriptToolError
    }
  }

  // MARK: 字段

  /// 四个字段原样读出；只有 title 时 value 为空，实际复制的内容回落到 title；null 等同缺省。
  @Test func parseListReadsFieldsAndDefaults() throws {
    let full = try ScriptToolProtocol.parseList(output([["title": "A", "subtitle": "B", "value": "C", "icon": "D"]]))
    #expect(full == [ToolListItem(title: "A", subtitle: "B", value: "C", icon: "D")])
    #expect(full[0].resolvedValue == "C")
    let minimal = try ScriptToolProtocol.parseList(Data(#"{"items":[{"title":"A"},{"title":"B","subtitle":null,"value":null}]}"#.utf8))
    #expect(minimal == [ToolListItem(title: "A"), ToolListItem(title: "B")])
    #expect(minimal.map(\.resolvedValue) == ["A", "B"])
    #expect(try ScriptToolProtocol.parseList(output([])) == [])
  }

  /// 多余的键（包括外层和嵌套结构）被忽略。
  @Test func parseListIgnoresUnknownFields() throws {
    let json = #"{"items":[{"title":"A","extra":1,"nested":{"x":[1,2]}}],"other":true,"version":2}"#
    #expect(try ScriptToolProtocol.parseList(Data(json.utf8)) == [ToolListItem(title: "A")])
  }

  /// 超过 200 项只取前 200 项，顺序不变；200 项及以下全部保留。
  @Test(arguments: [(199, 199), (200, 200), (201, 200), (500, 200)])
  func parseListKeepsFirstTwoHundredItems(total: Int, expected: Int) throws {
    let items = try ScriptToolProtocol.parseList(output((0..<total).map { ["title": String($0)] }))
    #expect(items.count == expected)
    #expect(items.map(\.title) == (0..<expected).map(String.init))
  }

  // MARK: title 与 subtitle

  /// title 恰好 256 个字符原样保留；超出的截成 255 个字符加 `…`，原始 title 存进 value。
  @Test func parseListTruncatesLongTitleAndKeepsOriginalAsValue() throws {
    let exact = try ScriptToolProtocol.parseList(output([["title": run("x", 256)]]))
    #expect(exact == [ToolListItem(title: run("x", 256))])
    for length in [257, 300, 5_000] {
      let original = run("x", length)
      let item = try #require(try ScriptToolProtocol.parseList(output([["title": original]])).first)
      #expect(item.title == run("x", 255) + "…")
      #expect(item.title.count == 256)
      #expect(item.value == original)
      #expect(item.resolvedValue == original)
    }
  }

  /// 按字符（不是字节）计数：汉字与组合 emoji 都算一个字符，不会被截成半个。
  @Test func parseListCountsCharactersNotBytes() throws {
    let chinese = try #require(try ScriptToolProtocol.parseList(output([["title": run("你", 256)]])).first)
    #expect(chinese.title == run("你", 256) && chinese.value == nil)
    let family = "👨‍👩‍👧"
    let long = String(repeating: family, count: 300)
    let item = try #require(try ScriptToolProtocol.parseList(output([["title": long]])).first)
    #expect(item.title == String(repeating: family, count: 255) + "…")
    #expect(item.value == long)
  }

  /// 控制字符与换行换成空格，title 因此被改动，原文进 value；已有 value 时不被覆盖。
  @Test(arguments: ["a\nb\tc", "ab\u{202E}cd", "ab\u{2028}cd", "a\r\nb"])
  func parseListReplacesControlCharactersInTitle(title: String) throws {
    let item = try #require(try ScriptToolProtocol.parseList(output([["title": title]])).first)
    #expect(!ToolTextRules.containsControlCharacters(item.title))
    #expect(item.title.contains(" ") && item.title != title)
    #expect(item.value == title)
    let explicit = try #require(try ScriptToolProtocol.parseList(output([["title": title, "value": "v"]])).first)
    #expect(explicit.value == "v")
  }

  /// 有 value 时，超长 title 只截断展示；value 不动，title 再长也不会因此报错。
  @Test func parseListKeepsExplicitValueWhenTitleIsTruncated() throws {
    let item = try #require(try ScriptToolProtocol.parseList(output([["title": run("x", 100_000), "value": "v"]])).first)
    #expect(item.title == run("x", 255) + "…")
    #expect(item.value == "v")
  }

  /// subtitle 恰好 512 个字符保留，超出截成 511 个字符加 `…`；换行换成空格；不影响 title 与 value。
  @Test func parseListTruncatesSubtitle() throws {
    let exact = try #require(try ScriptToolProtocol.parseList(output([["title": "t", "subtitle": run("s", 512)]])).first)
    #expect(exact.subtitle == run("s", 512))
    let long = try #require(try ScriptToolProtocol.parseList(output([["title": "t", "subtitle": run("s", 513)]])).first)
    #expect(long.subtitle == run("s", 511) + "…")
    #expect(long.title == "t" && long.value == nil)
    let multiline = try #require(try ScriptToolProtocol.parseList(output([["title": "t", "subtitle": "a\nb"]])).first)
    #expect(multiline.subtitle == "a b")
  }

  // MARK: 整份作废

  /// title 为空或只有空白：整份输出作废，错误里带出第几项。
  @Test(arguments: ["", "   ", "\n\t "])
  func parseListRejectsEmptyTitle(title: String) throws {
    let data = try output([["title": "ok"], ["title": title]])
    guard case .invalidListOutput(let reason)? = failure(data) else {
      Issue.record("应当以 invalidListOutput 失败")
      return
    }
    #expect(reason.contains("2"))
  }

  /// value 恰好 64 KiB 可以，多 1 字节整份作废；按 UTF-8 字节计，不是字符数。
  @Test func parseListRejectsValueOverSixtyFourKiB() throws {
    let limit = ScriptToolProtocol.listValueLimit
    let ok = try ScriptToolProtocol.parseList(output([["title": "t", "value": run("v", limit)]]))
    #expect(ok.first?.value?.utf8.count == limit)
    #expect(failure(try output([["title": "t", "value": run("v", limit + 1)]]))?.isInvalidListOutput == true)
    // 21845 个汉字 = 65535 字节可以，21846 个 = 65538 字节不行。
    #expect(failure(try output([["title": "t", "value": run("你", 21_845)]])) == nil)
    #expect(failure(try output([["title": "t", "value": run("你", 21_846)]]))?.isInvalidListOutput == true)
    // 后面的项出错也让前面的白做：整份作废而不是跳过坏项。
    #expect(failure(try output([["title": "a"], ["title": "b", "value": run("v", limit + 1)]]))?.isInvalidListOutput == true)
  }

  /// 没有 value 时超长 title 要整个存进 value：原文超过 64 KiB 就无法保存，整份作废。
  @Test func parseListRejectsOversizedTitleWithoutValue() throws {
    let limit = ScriptToolProtocol.listValueLimit
    let item = try #require(try ScriptToolProtocol.parseList(output([["title": run("x", limit)]])).first)
    #expect(item.value?.utf8.count == limit)
    #expect(failure(try output([["title": run("x", limit + 1)]]))?.isInvalidListOutput == true)
  }

  /// 不是 `{"items": [...]}` 结构、字段类型不对或 JSON 本身不完整：报 invalidListOutput。
  @Test(arguments: [
    "", "not json", "[]", "{}", #"{"items":"x"}"#, #"{"items":null}"#, #"{"items":[1]}"#, #"{"items":["a"]}"#,
    #"{"items":[{}]}"#, #"{"items":[{"title":1}]}"#, #"{"items":[{"title":null}]}"#, #"{"items":[{"subtitle":"s"}]}"#,
    #"{"items":[{"title":"a","subtitle":5}]}"#, #"{"items":[{"title":"a","value":[]}]}"#, #"{"items":[{"title":"a""#,
  ])
  func parseListRejectsMalformedOutput(json: String) {
    #expect(failure(Data(json.utf8))?.isInvalidListOutput == true, "\(json)")
  }

  // MARK: 输出大小

  /// stdout 恰好 1 MiB 还能解析，多 1 字节报 outputTooLarge；大小检查先于 JSON 解析。
  @Test func parseListEnforcesStdoutLimit() throws {
    let limit = ScriptToolProtocol.stdoutLimit
    let base = Data(#"{"items":[{"title":"a"}]}"#.utf8)
    let atLimit = base + Data(repeating: 0x20, count: limit - base.count)
    #expect(atLimit.count == limit)
    #expect(try ScriptToolProtocol.parseList(atLimit) == [ToolListItem(title: "a")])
    #expect(failure(atLimit + Data([0x20])) == .outputTooLarge)
    #expect(failure(Data(repeating: 0x61, count: limit + 1)) == .outputTooLarge)
    #expect(failure(Data(repeating: 0x61, count: limit))?.isInvalidListOutput == true)
  }
}

private extension ScriptToolError {
  /// 是不是 invalidListOutput（不比较提示文案）。
  var isInvalidListOutput: Bool {
    if case .invalidListOutput = self { return true }
    return false
  }
}
