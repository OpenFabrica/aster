// 清单功能校验：功能数量与代码、标题与关键词、match 规则（regex / text / files）与动作组合规则。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolManifestFeatureValidation")
struct ToolManifestFeatureValidationTests {
  typealias Fixture = ToolManifestFixture

  /// 夹具清单，第一个功能的 match 换成给定规则。
  private func manifest(rule: ToolMatchRule) -> ToolManifest {
    var manifest = Fixture.manifest()
    manifest.features[0].match = [rule]
    return manifest
  }

  /// features 1–32 项；code 格式合法且不重复。
  @Test func featureCountAndCodes() throws {
    var manifest = Fixture.manifest()
    manifest.features = []
    expectInvalid(manifest, field: "features")
    manifest.features = (0..<33).map { ToolFeature(code: "f\($0)", title: "T", keywords: ["k"], action: .ui) }
    expectInvalid(manifest, field: "features")
    manifest.features.removeLast()
    try manifest.validate(source: .user)
    for invalid in ["Decode", "-a", "_a", "a b", "a.b", "", String(repeating: "a", count: 33)] {
      manifest = Fixture.manifest()
      manifest.features[0].code = invalid
      expectInvalid(manifest, field: "features[0].code")
    }
    manifest = Fixture.manifest()
    manifest.features[0].code = "a_b-" + String(repeating: "c", count: 28)
    try manifest.validate(source: .user)
    manifest.features[1].code = manifest.features[0].code
    expectInvalid(manifest, field: "features[1].code")
  }

  /// title 必填 ≤ 64，subtitle ≤ 128，功能图标遵守图标路径规则。
  @Test func titleSubtitleAndIcon() {
    var manifest = Fixture.manifest()
    manifest.features[0].title = " "
    expectInvalid(manifest, field: "features[0].title")
    manifest.features[0].title = String(repeating: "t", count: 65)
    expectInvalid(manifest, field: "features[0].title")
    manifest = Fixture.manifest()
    manifest.features[0].subtitle = String(repeating: "s", count: 129)
    expectInvalid(manifest, field: "features[0].subtitle")
    manifest = Fixture.manifest()
    manifest.features[1].icon = "icon.bmp"
    expectInvalid(manifest, field: "features[1].icon")
  }

  /// keywords ≤ 8 项、每项 1–32 字符；match ≤ 8 条；至少有一个关键词或一条规则。
  @Test func keywordsAndRuleCounts() {
    var manifest = Fixture.manifest()
    manifest.features[0].keywords = (0..<9).map { "k\($0)" }
    expectInvalid(manifest, field: "features[0].keywords")
    manifest.features[0].keywords = ["ok", ""]
    expectInvalid(manifest, field: "features[0].keywords[1]")
    manifest.features[0].keywords = [String(repeating: "k", count: 33)]
    expectInvalid(manifest, field: "features[0].keywords[0]")
    manifest = Fixture.manifest()
    manifest.features[0].match = Array(repeating: .regex(ToolRegexRule(pattern: "x")), count: 9)
    expectInvalid(manifest, field: "features[0].match")
    manifest = Fixture.manifest()
    manifest.features[1].keywords = []
    expectInvalid(manifest, field: "features[1]")
  }

  /// regex 规则：能编译、≤ 512、不能产生空匹配；标签 ≤ 64；长度范围合法。
  @Test func regexRules() throws {
    try manifest(rule: .regex(ToolRegexRule(pattern: "^\\d{4}$", minLength: 4, maxLength: 1_048_576))).validate(source: .user)
    for pattern in ["(", "", "a*", "x?", "^", "$", "\\b", "(?=.)", "foo|", "(abc)?", String(repeating: "a", count: 513)] {
      expectInvalid(manifest(rule: .regex(ToolRegexRule(pattern: pattern))), field: "features[0].match[0].pattern")
    }
    expectInvalid(
      manifest(rule: .regex(ToolRegexRule(label: String(repeating: "l", count: 65), pattern: "x"))),
      field: "features[0].match[0].label")
    expectInvalid(manifest(rule: .regex(ToolRegexRule(pattern: "x", minLength: 0))), field: "features[0].match[0].minLength")
    expectInvalid(manifest(rule: .regex(ToolRegexRule(pattern: "x", maxLength: 0))), field: "features[0].match[0].maxLength")
    expectInvalid(
      manifest(rule: .regex(ToolRegexRule(pattern: "x", maxLength: 1_048_577))), field: "features[0].match[0].maxLength")
    expectInvalid(
      manifest(rule: .regex(ToolRegexRule(pattern: "x", minLength: 20, maxLength: 10))),
      field: "features[0].match[0].minLength")
    // 没写 maxLength 时按缺省 10,000 比较。
    expectInvalid(manifest(rule: .regex(ToolRegexRule(pattern: "x", minLength: 20_000))), field: "features[0].match[0].minLength")
  }

  /// text 规则：exclude 要能编译但允许空匹配；长度规则同 regex。
  @Test func textRules() throws {
    try manifest(rule: .text(ToolTextRule(exclude: "^\\s*$", minLength: 2))).validate(source: .user)
    try manifest(rule: .text(ToolTextRule())).validate(source: .user)
    expectInvalid(manifest(rule: .text(ToolTextRule(exclude: "("))), field: "features[0].match[0].exclude")
    expectInvalid(manifest(rule: .text(ToolTextRule(minLength: 0))), field: "features[0].match[0].minLength")
  }

  /// files 规则：扩展名与 pattern 二选一；扩展名小写无点、1–16 项；数量 1–100 且 min ≤ max。
  @Test func filesRules() throws {
    try manifest(rule: .files(ToolFilesRule(fileType: .file, extensions: ["png", "jpg"], minCount: 1, maxCount: 100)))
      .validate(source: .user)
    try manifest(rule: .files(ToolFilesRule(fileType: .directory, pattern: "^\\w+$"))).validate(source: .user)
    expectInvalid(manifest(rule: .files(ToolFilesRule(extensions: ["png"], pattern: "x"))), field: "features[0].match[0]")
    expectInvalid(manifest(rule: .files(ToolFilesRule(extensions: []))), field: "features[0].match[0].extensions")
    expectInvalid(
      manifest(rule: .files(ToolFilesRule(extensions: (0..<17).map { "e\($0)" }))), field: "features[0].match[0].extensions")
    for invalid in ["PNG", ".png", "tar.gz", "", "a b", "a/b"] {
      expectInvalid(
        manifest(rule: .files(ToolFilesRule(extensions: ["ok", invalid]))), field: "features[0].match[0].extensions[1]")
    }
    expectInvalid(manifest(rule: .files(ToolFilesRule(pattern: "("))), field: "features[0].match[0].pattern")
    expectInvalid(manifest(rule: .files(ToolFilesRule(minCount: 0))), field: "features[0].match[0].minCount")
    expectInvalid(manifest(rule: .files(ToolFilesRule(maxCount: 101))), field: "features[0].match[0].maxCount")
    expectInvalid(manifest(rule: .files(ToolFilesRule(minCount: 5, maxCount: 3))), field: "features[0].match[0].minCount")
  }

  /// ui 动作需要清单的 ui；builtin 动作只给内置来源。
  @Test func uiAndBuiltinActions() throws {
    var manifest = Fixture.manifest()
    manifest.ui = nil
    expectInvalid(manifest, field: "features[0].action")
    manifest = Fixture.manifest()
    manifest.features[0].action = .builtin(ToolBuiltinAction(handler: .json))
    expectInvalid(manifest, source: .user, field: "features[0].action")
    expectInvalid(manifest, source: .development, field: "features[0].action")
    try manifest.validate(source: .builtin)
  }

  /// 脚本动作：需要 exec 权限；command 1–32 项、每项 ≤ 4096 字节且无控制字符；相对 command[0] 遵守路径规则；超时 1–60。
  @Test func scriptActions() throws {
    var manifest = Fixture.manifest()
    manifest.permissions = [.clipboardWrite]
    expectInvalid(manifest, field: "features[1].action")
    let cases: [([String], String)] = [
      ([], "features[1].action.command"),
      (Array(repeating: "a", count: 33), "features[1].action.command"),
      (["bin/run", String(repeating: "x", count: 4_097)], "features[1].action.command[1]"),
      (["bin/run", "a\u{1B}[2J"], "features[1].action.command[1]"),
      ([""], "features[1].action.command[0]"),
      (["../run"], "features[1].action.command[0]"),
      (["bin/" + String(repeating: "r", count: 260)], "features[1].action.command[0]"),
    ]
    for (command, field) in cases {
      manifest = Fixture.manifest()
      manifest.features[1].action = .script(ToolScriptAction(command: command))
      expectInvalid(manifest, field: field)
    }
    manifest = Fixture.manifest()
    manifest.features[1].action = .script(ToolScriptAction(command: ["/usr/bin/env", "python3", String(repeating: "x", count: 4_096)]))
    try manifest.validate(source: .user)
    for timeout in [1.0, 60.0] {
      manifest.features[1].action = .script(ToolScriptAction(command: ["bin/run"], timeout: timeout))
      try manifest.validate(source: .user)
    }
    for timeout in [0.5, 61.0] {
      manifest.features[1].action = .script(ToolScriptAction(command: ["bin/run"], timeout: timeout))
      expectInvalid(manifest, field: "features[1].action.timeout")
    }
  }
}
