import Foundation

// 命令片段（Snippet）：保存为 `.commands` scope 的 Recipe，不另建存储。
//
// 这里只放与界面无关的规则：编辑器字段 ↔ Recipe、粘贴文本、标签与主机标签的匹配度、
// 文件名。打开与运行仍走 `WorkflowRecipeOpenPlanner` 的信任审查与重放确认。

public enum WorkflowSnippet {
  /// 用编辑器字段构造片段：命令一行一条（去掉首尾空白行与空行），标签逗号分隔（中英文逗号都可）。
  /// 结果经 `WorkflowRecipeTOML.validate` 校验，非法时抛同一组错误。
  public static func make(name: String, commandsText: String, tagsText: String) throws -> WorkflowRecipe {
    let recipe = WorkflowRecipe(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      scope: .commands,
      content: .includeCommands,
      commands: commands(from: commandsText),
      tags: tags(from: tagsText))
    try WorkflowRecipeTOML.validate(recipe)
    return recipe
  }

  /// 多行文本拆成命令：按行切分，丢弃只含空白的行，保留行内原样（含行首缩进）。
  public static func commands(from text: String) -> [String] {
    text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// 逗号分隔的标签文本：去空白、丢空串、不分大小写去重，与主机标签同一套规范化。
  public static func tags(from text: String) -> [String] {
    let parts = text.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init)
    return SSHHostStore.normalizedTags(parts) ?? []
  }

  /// 粘贴到 Pane 的文本：命令按行连接，末尾不带换行，粘贴后不会自动执行。
  public static func pasteText(_ recipe: WorkflowRecipe) -> String {
    recipe.commands.joined(separator: "\n")
  }

  /// 片段标签与当前主机标签的交集数（不分大小写）；用于在 SSH Pane 里把相关片段排前。
  public static func tagOverlap(snippetTags: [String], hostTags: [String]) -> Int {
    let host = Set(hostTags.map { $0.lowercased() })
    return Set(snippetTags.map { $0.lowercased() }).intersection(host).count
  }

  /// 片段名对应的安全文件名主体：只保留字母、数字、`.`、`_`、`-`，其余连成 `-`；全被替换时用 `snippet`。
  public static func fileStem(for name: String) -> String {
    let stem = name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return stem.isEmpty ? "snippet" : stem
  }
}
