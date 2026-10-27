// 两个启动器共用的结果组装：特定内容的「识别到」在前、搜索结果居中、只认「是文字」的识别到垫底，同一功能只出现一次；
// 以及「拿什么去做内容匹配」「打开时交给工具什么输入」两条规则。
import AsterCore
import Foundation

/// 启动器里的一行工具。
struct ToolLauncherRow: Equatable {
  /// 行从哪里来。
  enum Origin: Equatable {
    /// 输入内容命中 match 规则（「识别到」）。
    case recognized
    /// 关键词搜索，或空查询时的最近常用。
    case search
  }

  let origin: Origin
  let entry: ToolCatalogEntry
  let title: String
  let detail: String
  let badge: String
  let symbol: String
  /// 内置转换立即算出的结果。只在「识别到」行上计算；有它时 `↩` 复制、`⌘↩` 预填。
  let inlineResult: String?

  /// 行身份。同一功能的「识别到」行与搜索行身份不同；Open Quickly 也直接用它当条目 id。
  var id: String {
    switch origin {
    case .recognized: "tool-match:\(entry.id)"
    case .search: "tool:\(entry.id)"
    }
  }
}

/// 结果组装规则。
enum ToolLauncherResults {
  /// 排序：regex / files 规则的「识别到」在前，搜索结果居中，text 规则的「识别到」垫底。
  /// 同一功能只出现一次，先排到的那行留下，否则同一个工具连着两行，用户分不清该点哪一行。
  static func rows(
    recognized: [ToolMatch],
    searched: [ToolMatch],
    inlineResult: (ToolMatch) -> String?
  ) -> [ToolLauncherRow] {
    var seen = Set<String>()
    var rows: [ToolLauncherRow] = []
    // text 规则接受任意文字：输入「json」时 Hash 也会命中。它若排在搜索结果前面，默认选中的就是 Hash，
    // `↩` 复制的是「json」的哈希，而不是打开用户在找的 JSON 工具。所以只有 regex / files 命中才置顶；
    // text 命中放到最后，同一功能也被关键词搜到时留搜索行，用户输入的是工具名，不是待处理内容。
    let appendRecognized = { (match: ToolMatch) in
      guard seen.insert(match.entry.id).inserted else { return }
      let result = inlineResult(match)
      rows.append(
        ToolLauncherRow(
          origin: .recognized, entry: match.entry,
          title: ToolEntryPresentation.matchTitle(for: match),
          detail: ToolEntryPresentation.matchDetail(for: match, inlineResult: result),
          badge: L("识别到"), symbol: ToolEntryPresentation.symbol(for: match.entry),
          inlineResult: result))
    }
    recognized.filter { !$0.isTextRuleMatch }.forEach(appendRecognized)
    for match in searched where seen.insert(match.entry.id).inserted {
      rows.append(
        ToolLauncherRow(
          origin: .search, entry: match.entry, title: match.entry.feature.title,
          detail: ToolEntryPresentation.detail(for: match.entry),
          badge: ToolEntryPresentation.badge(for: match.entry),
          symbol: ToolEntryPresentation.symbol(for: match.entry), inlineResult: nil))
    }
    recognized.filter(\.isTextRuleMatch).forEach(appendRecognized)
    return rows
  }

  /// 做内容匹配用的输入。拖入了文件时只匹配文件，搜索框里的字此时是在筛工具，不是待处理内容；
  /// 没有文件时把整段查询文字当内容（不裁剪，前后空白也可能是内容的一部分），全是空白则不匹配。
  static func contentInput(query: String, files: [String], context: ToolContext) -> ToolInput? {
    if !files.isEmpty { return ToolInput(files: files, source: .file, context: context) }
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return ToolInput(text: query, source: .typed, context: context)
  }

  /// 打开某一行时交给工具的输入：「识别到」行用参与匹配的那份内容；搜索行的查询文字只是工具名，
  /// 不当输入，但拖入的文件仍然带上。
  static func launchInput(
    for row: ToolLauncherRow,
    contentInput: ToolInput?,
    files: [String],
    context: ToolContext
  ) -> ToolInput {
    if row.origin == .recognized, let contentInput { return contentInput }
    if !files.isEmpty { return ToolInput(files: files, source: .file, context: context) }
    return ToolInput(context: context)
  }
}
