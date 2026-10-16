import AsterCore
import Foundation

// Open Quickly「Recipes」小节的行计算：命令片段（`.commands` scope）与布局 Recipe 分开呈现。
//
// 片段的主动作是粘贴到当前 Pane（不回车），运行与在新标签页打开放在菜单里；布局 Recipe
// 保持原来的「打开 Recipe」。当前 Pane 是原生 SSH 主机时，标签与主机标签有交集的片段排前。
// 纯计算放在这里便于测试，`OpenQuicklyOverlay` 只负责把行变成可点击的目标。

enum OpenQuicklySnippetCatalog {
  /// 一行结果。`snippet` 非 nil 表示命令片段。
  struct Row: Equatable {
    var url: URL
    var title: String
    var detail: String
    /// 同匹配质量内的排序分；片段等于与当前主机标签的交集数。
    var score: Double
    var snippet: WorkflowRecipe?

    var id: String { "recipe:\(url.path)" }
  }

  /// 读取每个 Recipe 文件并生成行。读不出来的文件仍按普通 Recipe 列出，打开时再报告错误。
  static func rows(urls: [URL], hostTags: [String], load: (URL) throws -> WorkflowRecipe) -> [Row] {
    urls.map { url in
      let fileTitle = url.deletingPathExtension().lastPathComponent
      guard let recipe = try? load(url), recipe.scope == .commands else {
        return Row(url: url, title: fileTitle, detail: url.path, score: 0, snippet: nil)
      }
      return Row(
        url: url, title: recipe.name, detail: detail(for: recipe),
        score: Double(WorkflowSnippet.tagOverlap(snippetTags: recipe.tags, hostTags: hostTags)),
        snippet: recipe)
    }
  }

  /// 片段的 detail：首条命令（多条时注明总数）加 `#tag`，模糊搜索能命中命令与标签。
  static func detail(for recipe: WorkflowRecipe) -> String {
    let count = recipe.commands.count > 1 ? L("共 \(recipe.commands.count) 条") : ""
    let tags = recipe.tags.map { "#\($0)" }.joined(separator: " ")
    return [recipe.commands.first ?? "", count, tags].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
