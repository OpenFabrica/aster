// 两个启动器共用的结果组装、输入规则与展示规则，以及 Open Quickly 工具行的过滤器、小节顺序与插入位置。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 构造一个工具条目。
private func entry(
  _ code: String,
  pluginID: String = "aster.builtin",
  source: ToolPluginSource = .builtin,
  action: ToolAction = .builtin(ToolBuiltinAction(handler: .json)),
  subtitle: String? = nil,
  match: [ToolMatchRule] = []
) -> ToolCatalogEntry {
  ToolCatalogEntry(
    pluginID: pluginID, pluginName: "Plugin", pluginVersion: "1.0.0", source: source,
    feature: ToolFeature(
      code: code, title: "Title \(code)", subtitle: subtitle, keywords: [code], match: match, action: action))
}

/// 关键词搜索命中。
private func searchMatch(_ entry: ToolCatalogEntry) -> ToolMatch {
  ToolMatch(entry: entry, reason: .search, score: 100)
}

/// 内容规则命中（「识别到」）。
private func contentMatch(_ entry: ToolCatalogEntry, label: String?) -> ToolMatch {
  ToolMatch(entry: entry, reason: .content(ruleIndex: 0, label: label), score: 200)
}

@Test("认出具体格式的「识别到」在前、搜索在后，同一功能只出现一次；只有识别到的行带行内结果")
func launcherRowsPutRecognizedFirstAndDeduplicate() {
  let timestamp = entry("timestamp")
  let json = entry("json")
  let hash = entry("hash")
  let rows = ToolLauncherResults.rows(
    recognized: [contentMatch(timestamp, label: "转成日期"), contentMatch(hash, label: nil)],
    searched: [searchMatch(json), searchMatch(timestamp)]
  ) { match in match.entry.id == timestamp.id ? "2023-11-15 06:13:20\nUTC" : nil }

  #expect(rows.map(\.id) == ["tool-match:aster.builtin/timestamp", "tool-match:aster.builtin/hash", "tool:aster.builtin/json"])
  #expect(rows.map(\.origin) == [.recognized, .recognized, .search])
  #expect(rows[0].title == "转成日期")
  // 多行结果在行内压成一行，完整结果仍保留给复制与预填。
  #expect(rows[0].detail == "2023-11-15 06:13:20 UTC")
  #expect(rows[0].inlineResult == "2023-11-15 06:13:20\nUTC")
  #expect(rows[1].title == "Title hash")
  #expect(rows[1].detail == "Title hash · Plugin")
  #expect(rows[1].inlineResult == nil)
  #expect(rows[2].inlineResult == nil)
  #expect(rows[2].detail == "Plugin")
}

@Test("只认「是文字」的识别到排在搜索结果后面；同一功能也被搜到时只留搜索行，也不再算行内结果")
func launcherRowsPutTextRuleMatchesAfterSearch() {
  let anyText: [ToolMatchRule] = [.text(ToolTextRule(label: "计算 Hash"))]
  let timestamp = entry("timestamp", match: [.regex(ToolRegexRule(pattern: "\\d"))])
  let hash = entry("hash", match: anyText)
  let counter = entry("counter", match: anyText)
  let json = entry("json")
  var computed: [String] = []
  let rows = ToolLauncherResults.rows(
    recognized: [contentMatch(timestamp, label: nil), contentMatch(hash, label: nil), contentMatch(counter, label: nil)],
    searched: [searchMatch(json), searchMatch(counter)]
  ) { match in
    computed.append(match.entry.feature.code)
    return nil
  }

  #expect(
    rows.map(\.id) == [
      "tool-match:aster.builtin/timestamp", "tool:aster.builtin/json", "tool:aster.builtin/counter",
      "tool-match:aster.builtin/hash",
    ])
  #expect(computed == ["timestamp", "hash"])
}

@Test("内容匹配的输入：拖入文件时只匹配文件，否则把查询原文当内容，全空白不匹配")
func launcherContentInputRules() throws {
  let context = ToolContext(workingDirectory: "/tmp", isRemote: false, locale: "zh-Hans", appearance: "dark")
  #expect(ToolLauncherResults.contentInput(query: "   ", files: [], context: context) == nil)
  let typed = try #require(ToolLauncherResults.contentInput(query: " {\"a\":1} ", files: [], context: context))
  #expect(typed.text == " {\"a\":1} ")
  #expect(typed.source == .typed)
  #expect(typed.context == context)
  let dropped = try #require(ToolLauncherResults.contentInput(query: "json", files: ["/tmp/a.json"], context: context))
  #expect(dropped.text == nil)
  #expect(dropped.files == ["/tmp/a.json"])
  #expect(dropped.source == .file)
}

@Test("打开时的输入：识别到的行带匹配内容，搜索行只带拖入的文件")
func launcherLaunchInputRules() throws {
  let context = ToolContext()
  let rows = ToolLauncherResults.rows(
    recognized: [contentMatch(entry("url"), label: nil)], searched: [searchMatch(entry("uuid"))]
  ) { _ in nil }
  let content = ToolInput(text: "a%20b", source: .typed, context: context)
  let recognized = ToolLauncherResults.launchInput(for: rows[0], contentInput: content, files: [], context: context)
  #expect(recognized == content)
  let searched = ToolLauncherResults.launchInput(for: rows[1], contentInput: content, files: [], context: context)
  #expect(searched == ToolInput(context: context))
  let withFiles = ToolLauncherResults.launchInput(for: rows[1], contentInput: nil, files: ["/tmp/x"], context: context)
  #expect(withFiles.files == ["/tmp/x"])
  #expect(withFiles.source == .file)
}

@Test("徽章与图标：内置来源一律「内置」，用户插件按运行方式区分")
func toolEntryPresentationBadgesAndSymbols() {
  let builtinWeb = entry("jwt", pluginID: "aster.jwt", source: .builtin, action: .ui)
  let userWeb = entry("diff", pluginID: "com.example.diff", source: .user, action: .ui)
  let script = entry(
    "now", pluginID: "com.example.now", source: .development,
    action: .script(ToolScriptAction(command: ["bin/now.sh"])), subtitle: "秒")
  #expect(ToolEntryPresentation.badge(for: entry("json")) == L("内置"))
  #expect(ToolEntryPresentation.badge(for: builtinWeb) == L("内置"))
  #expect(ToolEntryPresentation.badge(for: userWeb) == L("网页"))
  #expect(ToolEntryPresentation.badge(for: script) == L("脚本"))
  #expect(ToolEntryPresentation.symbol(for: entry("json")) == "wand.and.stars")
  #expect(ToolEntryPresentation.symbol(for: userWeb) == "macwindow")
  #expect(ToolEntryPresentation.symbol(for: script) == "terminal")
  #expect(ToolEntryPresentation.detail(for: script) == "Plugin · 秒")
  #expect(ToolEntryPresentation.singleLine(String(repeating: "a", count: 300), limit: 10) == "aaaaaaaaaa…")
}

@Test("Open Quickly：「工具」页空查询列全部，「全部」空查询不列工具，其它过滤器不列")
func openQuicklyToolRowsFollowFilterRules() {
  #expect(OpenQuicklyToolCatalog.limits(filter: .tool, query: "")?.recognized == 0)
  #expect((OpenQuicklyToolCatalog.limits(filter: .tool, query: "")?.search ?? 0) > 0)
  #expect((OpenQuicklyToolCatalog.limits(filter: .tool, query: "json")?.recognized ?? 0) > 0)
  #expect(OpenQuicklyToolCatalog.limits(filter: .all, query: "") == nil)
  #expect(OpenQuicklyToolCatalog.limits(filter: .all, query: "  ") == nil)
  let all = OpenQuicklyToolCatalog.limits(filter: .all, query: "1700000000")
  #expect((all?.search ?? 0) > 0 && (all?.recognized ?? 0) > 0)
  for filter in OpenQuicklyFilter.allCases where filter != .tool && filter != .all {
    #expect(OpenQuicklyToolCatalog.limits(filter: filter, query: "json") == nil)
  }
}

@Test("Open Quickly：工具行插在文件之前，没有文件时放末尾，同 id 不重复")
func openQuicklyToolRowsInsertBeforeFiles() {
  let tool = OpenQuicklyItem(id: "tool:a/b", kind: .tool, title: "Tool")
  let items = [
    OpenQuicklyItem(id: "opened:1", kind: .opened, title: "Tab"),
    OpenQuicklyItem(id: "agent:1", kind: .agent, title: "Agent"),
    OpenQuicklyItem(id: "file:1", kind: .file, title: "File"),
  ]
  #expect(
    OpenQuicklyToolCatalog.inserting([tool], into: items).map(\.id)
      == ["opened:1", "agent:1", "tool:a/b", "file:1"])
  #expect(OpenQuicklyToolCatalog.inserting([tool], into: Array(items.prefix(2))).map(\.id) == ["opened:1", "agent:1", "tool:a/b"])
  #expect(OpenQuicklyToolCatalog.inserting([tool], into: items + [tool]).filter { $0.id == tool.id }.count == 1)
  #expect(OpenQuicklyToolCatalog.inserting([], into: items) == items)
}

@Test("Open Quickly「工具」过滤器只含工具，小节排在智能体之后、文件之前")
func openQuicklyToolFilterAndPriority() {
  let items = [
    OpenQuicklyItem(id: "file", kind: .file, title: "json.swift"),
    OpenQuicklyItem(id: "tool", kind: .tool, title: "JSON 格式化"),
    OpenQuicklyItem(id: "agent", kind: .agent, title: "json agent"),
    OpenQuicklyItem(id: "recipe", kind: .recipe, title: "json recipe"),
  ]
  let index = OpenQuicklyIndex(items: items)
  #expect(index.search(query: "json", filter: .tool).map(\.id) == ["tool"])
  #expect(index.search(query: "json", filter: .all).map(\.id) == ["recipe", "agent", "tool", "file"])
  #expect(OpenQuicklyFilter.allCases.firstIndex(of: .tool) == OpenQuicklyFilter.allCases.firstIndex(of: .recipe).map { $0 + 1 })
  #expect(OpenQuicklyFilter.allCases.last == .file)
}
