// 工具条目在两个启动器（Open Quickly「工具」页与工具面板）里的展示规则：标题、副标题、徽章与图标。
// 两处共用同一份规则，同一个功能在哪里看起来都一样。
import AsterCore
import Foundation

/// 工具条目的纯展示计算。
enum ToolEntryPresentation {
  /// 静态行的副标题：「插件名 · 功能副标题」；功能没有副标题时只写插件名。
  static func detail(for entry: ToolCatalogEntry) -> String {
    guard let subtitle = entry.feature.subtitle, !subtitle.isEmpty else { return entry.pluginName }
    return "\(entry.pluginName) · \(subtitle)"
  }

  /// 来源徽章：随 App 发布的一律是「内置」；用户与开发插件按运行方式分「网页」「脚本」。
  /// 清单校验只允许内置来源使用 builtin 动作，最后一支是防御性的兜底。
  static func badge(for entry: ToolCatalogEntry) -> String {
    if entry.source == .builtin { return L("内置") }
    switch entry.feature.action {
    case .ui: return L("网页")
    case .script: return L("脚本")
    case .builtin: return L("插件")
    }
  }

  /// 行图标（SF Symbol）。启动器的行没有自定义图片位，按动作类型选符号。
  static func symbol(for entry: ToolCatalogEntry) -> String {
    switch entry.feature.action {
    case .builtin: "wand.and.stars"
    case .ui: "macwindow"
    case .script: "terminal"
    }
  }

  /// 「识别到」行的标题：命中规则的标签优先（例如「转成日期」），没有标签用功能标题。
  static func matchTitle(for match: ToolMatch) -> String {
    if case .content(_, let label?) = match.reason, !label.isEmpty { return label }
    return match.entry.feature.title
  }

  /// 「识别到」行的副标题：能立即算出结果时直接显示结果（压成一行），否则写功能与插件名。
  static func matchDetail(for match: ToolMatch, inlineResult: String?) -> String {
    if let inlineResult, !inlineResult.isEmpty { return singleLine(inlineResult) }
    return "\(match.entry.feature.title) · \(match.entry.pluginName)"
  }

  /// 把多行结果压成一行用于行内显示；完整结果仍按原文复制或预填。
  static func singleLine(_ text: String, limit: Int = 240) -> String {
    let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
  }
}
