// 内置工具清单：能通过内置来源的校验，正则有效且不匹配空串，关键词兼顾中英文。
import Foundation
import Testing

@testable import AsterCore

@Suite("BuiltinToolCatalog")
struct BuiltinToolCatalogTests {
  /// 内置清单按内置来源校验通过；同一份清单换成用户来源会因 `aster.` 前缀与 builtin 动作被拒。
  @Test func manifestValidatesAsBuiltinOnly() throws {
    let manifest = BuiltinToolCatalog.manifest()
    try manifest.validate(source: .builtin)
    #expect(manifest.id == BuiltinToolCatalog.pluginID)
    #expect(throws: ToolManifestError.self) { try manifest.validate(source: .user) }
  }

  /// 每个处理器恰好对应一个功能，功能代码就是处理器原始值。
  @Test func everyHandlerHasOneFeature() throws {
    let features = BuiltinToolCatalog.manifest().features
    #expect(features.map(\.code) == ToolBuiltinHandler.allCases.map(\.rawValue))
    for feature in features {
      let handler = try #require(ToolBuiltinHandler(rawValue: feature.code))
      #expect(feature.action == .builtin(ToolBuiltinAction(handler: handler)))
    }
  }

  /// 所有 match 正则都能编译，且不会产生空匹配。
  @Test func regexRulesCompileAndNeverMatchEmpty() throws {
    for feature in BuiltinToolCatalog.manifest().features {
      for rule in feature.match {
        guard case .regex(let regex) = rule else { continue }
        let expression = try NSRegularExpression(pattern: regex.pattern)
        #expect(!ToolRegex.canMatchEmpty(expression), "\(feature.code): \(regex.pattern)")
      }
    }
  }

  /// 关键词同时含中文与英文，方便两种输入习惯。
  @Test func keywordsMixChineseAndEnglish() {
    for feature in BuiltinToolCatalog.manifest().features {
      let hasHan = feature.keywords.contains { $0.unicodeScalars.contains(where: \.properties.isIdeographic) }
      let hasLatin = feature.keywords.contains { $0.unicodeScalars.allSatisfy(\.isASCII) }
      #expect(hasHan && hasLatin, "\(feature.code)")
    }
  }

  /// 正则粗筛命中典型输入：时间戳、日期、Base64、URL、端口、JSON。
  @Test(arguments: [
    (ToolBuiltinHandler.timestamp, "1700000000"),
    (.timestamp, " 1700000000123\n"),
    (.timestamp, "2024-01-02 03:04:05"),
    (.timestamp, "2024-01-02T03:04:05.123+08:00"),
    (.timestamp, "2024/1/2"),
    (.timestamp, "2024年1月2日 03:04"),
    (.base64, "aGVsbG8gd29ybGQ="),
    (.url, "a%20b"),
    (.url, "https://example.com/path?q=1"),
    (.ports, ":8080"),
    (.json, "  {\"a\": 1}"),
  ])
  func patternsRecognizeTypicalInput(handler: ToolBuiltinHandler, text: String) throws {
    let feature = try #require(BuiltinToolCatalog.manifest().features.first { $0.code == handler.rawValue })
    let matched = feature.match.contains { rule in
      guard case .regex(let regex) = rule, let expression = ToolRegex.compiled(regex.pattern) else { return false }
      return ToolRegex.firstMatch(expression, in: text, allowsEmptyMatch: false) == .matched
    }
    #expect(matched)
  }
}
