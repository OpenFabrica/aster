// 匹配器测试的公共构造：快速生成目录条目与内置工具条目。
import Foundation

@testable import AsterCore

enum ToolMatcherFixture {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// 一个网页功能条目。
  static func entry(
    plugin: String = "com.example.tool",
    name: String = "Example",
    code: String,
    title: String,
    subtitle: String? = nil,
    keywords: [String] = [],
    match: [ToolMatchRule] = [],
    source: ToolPluginSource = .user
  ) -> ToolCatalogEntry {
    ToolCatalogEntry(
      pluginID: plugin, pluginName: name, pluginVersion: "1.0.0", source: source,
      feature: ToolFeature(code: code, title: title, subtitle: subtitle, keywords: keywords, match: match, action: .ui),
      hasUI: true)
  }

  /// 内置清单的全部功能条目。
  static func builtinEntries() -> [ToolCatalogEntry] {
    let manifest = BuiltinToolCatalog.manifest()
    return manifest.features.map {
      ToolCatalogEntry(
        pluginID: manifest.id, pluginName: manifest.name, pluginVersion: manifest.version, source: .builtin, feature: $0)
    }
  }

  /// 只有若干次使用记录的统计，全部记在 `now`。
  static func usage(_ counts: [String: Int]) -> ToolUsageStats {
    ToolUsageStats(records: counts.mapValues { ToolUsageRecord(count: $0, lastUsed: now) })
  }

  /// 搜索结果的功能代码，按顺序。
  static func searchCodes(
    _ query: String,
    _ entries: [ToolCatalogEntry],
    usage: ToolUsageStats = ToolUsageStats(),
    limit: Int = 50
  ) -> [String] {
    ToolMatcher.search(query, entries: entries, usage: usage, now: now, limit: limit).map(\.entry.feature.code)
  }
}
