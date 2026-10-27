// 内置网页插件清单文案的翻译：只换显示文字（名称、说明、标题、副标题、匹配标签），关键词与行为字段不变；
// 只有内置来源翻译，用户与开发插件原样显示，原生内置工具不重复翻译。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolRuntimeLocalizationTests {
  @Test func localizedForBuiltinTranslatesDisplayTextOnly() {
    let regex = ToolMatchRule.regex(ToolRegexRule(label: "识别", pattern: "^a+$", maxLength: 10))
    let files = ToolMatchRule.files(ToolFilesRule(extensions: ["png"]))
    let manifest = ToolManifest(
      id: "aster.sample", name: "示例", version: "1.0.0", description: "说明",
      ui: ToolUIConfig(main: "index.html"), permissions: [.clipboardWrite],
      features: [
        ToolFeature(
          code: "open", title: "打开", subtitle: "副标题", keywords: ["sample", "示例"], match: [regex, files],
          action: .ui),
        ToolFeature(code: "plain", title: "朴素", keywords: ["plain"], action: .ui),
      ])
    let localized = manifest.localizedForBuiltin { "<\($0)>" }

    #expect(localized.name == "<示例>")
    #expect(localized.description == "<说明>")
    #expect(localized.features.map(\.title) == ["<打开>", "<朴素>"])
    #expect(localized.features.map(\.subtitle) == ["<副标题>", nil])
    #expect(localized.features[0].match.map(\.label) == ["<识别>", nil])
    // 关键词保留原文供搜索；id、动作、权限、规则本身都不动。
    #expect(localized.features[0].keywords == ["sample", "示例"])
    #expect(localized.id == manifest.id)
    #expect(localized.permissions == manifest.permissions)
    #expect(localized.features.map(\.action) == manifest.features.map(\.action))
    guard case .regex(let rule) = localized.features[0].match[0] else {
      Issue.record("规则种类变了")
      return
    }
    #expect(rule.pattern == "^a+$")
    #expect(manifest.localizedForBuiltin { $0 } == manifest)
  }

  @Test func onlyBuiltinWebPluginsAreTranslated() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let feature: [String: Any] = [
      "code": "open", "title": "打开示例", "subtitle": "副标题", "keywords": ["sample"],
      "match": [["type": "regex", "label": "识别示例", "pattern": "^sample-\\d+$"]],
      "action": ["type": "ui"],
    ]
    try writeToolPlugin(
      at: sandbox.builtinDirectory.appendingPathComponent("aster.sample"), id: "aster.sample", name: "示例",
      permissions: [], features: [feature], ui: ["main": "index.html"])
    try writeToolPlugin(
      at: sandbox.pluginsDirectory.appendingPathComponent("user"), id: "com.example.user", name: "用户插件",
      features: [echoFeature(title: "用户功能")])
    let center = sandbox.makeCenter { "EN:" + $0 }
    await center.reloadAndWait()

    let builtin = try #require(center.entry(id: "aster.sample/open"))
    #expect(builtin.pluginName == "EN:示例")
    #expect(builtin.feature.title == "EN:打开示例")
    #expect(builtin.feature.subtitle == "EN:副标题")
    #expect(builtin.feature.keywords == ["sample"])
    let user = try #require(center.entry(id: "com.example.user/run"))
    #expect(user.pluginName == "用户插件")
    #expect(user.feature.title == "用户功能")
    // 原生内置工具的标题已经由 L() 生成，不再套一层翻译。
    let native = BuiltinToolCatalog.manifest().feature(code: "uuid")?.title
    #expect(center.entry(id: "aster.builtin/uuid")?.feature.title == native)

    let summaries = Dictionary(uniqueKeysWithValues: center.pluginSummaries.map { ($0.id, $0.name) })
    #expect(summaries["aster.sample"] == "EN:示例")
    #expect(summaries["com.example.user"] == "用户插件")
    #expect(center.search("EN:打开", limit: 5).map(\.entry.id) == ["aster.sample/open"])
    let match = center.contentMatches(for: ToolInput(text: "sample-42"), limit: 5)
      .first { $0.entry.id == "aster.sample/open" }
    #expect(match?.reason == .content(ruleIndex: 0, label: "EN:识别示例"))
  }
}
