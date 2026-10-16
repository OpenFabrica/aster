import AsterCore
import Foundation
import Testing

@testable import Aster

// Open Quickly 的片段行与片段文件定位：片段与布局 Recipe 分开呈现，主机标签影响排序分，
// 文件操作只限 Recipes 目录。

private struct UnreadableRecipe: Error {}

@Test("片段行用片段名与首条命令 + #标签；布局与读不出的 Recipe 保持文件名；分数等于主机标签交集")
func snippetCatalogBuildsRows() throws {
  let snippet = WorkflowRecipe(
    name: "重启 API", scope: .commands, content: .includeCommands,
    commands: ["sudo systemctl restart api", "journalctl -u api"], tags: ["prod", "api"])
  let single = WorkflowRecipe(name: "看日志", scope: .commands, content: .includeCommands, commands: ["tail -f log"])
  let layout = WorkflowRecipe(
    name: "dev", scope: .tab, content: .layoutOnly,
    tabs: [WorkflowRecipeTab(title: "A", panes: [WorkflowRecipePane(workingDirectory: "{{current_folder}}")])])
  let recipes: [String: WorkflowRecipe] = ["/r/a.asterrecipe": snippet, "/r/b.asterrecipe": single, "/r/c.asterrecipe": layout]
  let urls = ["/r/a.asterrecipe", "/r/b.asterrecipe", "/r/c.asterrecipe", "/r/d.asterrecipe"].map { URL(fileURLWithPath: $0) }

  let rows = OpenQuicklySnippetCatalog.rows(urls: urls, hostTags: ["PROD"]) { url in
    guard let recipe = recipes[url.path] else { throw UnreadableRecipe() }
    return recipe
  }
  #expect(rows.map(\.title) == ["重启 API", "看日志", "c", "d"])
  #expect(rows[0].detail == "sudo systemctl restart api · 共 2 条 · #prod #api")
  #expect(rows[0].score == 1)
  #expect(rows[1].detail == "tail -f log")
  #expect(rows[1].score == 0)
  #expect(rows[2].snippet == nil && rows[2].detail == "/r/c.asterrecipe")
  #expect(rows[3].snippet == nil)
  #expect(rows[0].id == "recipe:/r/a.asterrecipe")
}

@Test("片段文件：新建不覆盖同名文件；只接受 Recipes 目录里的 .asterrecipe；布局 Recipe 不是片段")
func snippetRecipeFilesStayInsideDirectory() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AsterSnippets-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let first = SnippetRecipeFiles.newURL(for: "deploy", in: directory)
  #expect(first.lastPathComponent == "deploy.asterrecipe")
  let snippet = WorkflowRecipe(name: "deploy", scope: .commands, content: .includeCommands, commands: ["make"])
  try WorkflowRecipeTOML.save(snippet, to: first)
  #expect(SnippetRecipeFiles.newURL(for: "deploy", in: directory).lastPathComponent == "deploy-2.asterrecipe")

  #expect(try SnippetRecipeFiles.validatedURL(first.path, in: directory) == first.standardizedFileURL)
  #expect(try SnippetRecipeFiles.loadSnippet(at: first) == snippet)
  for path in ["/etc/passwd", directory.appendingPathComponent("../x.asterrecipe").path, directory.appendingPathComponent("a.txt").path] {
    #expect(throws: SnippetRecipeFiles.FileError.outsideDirectory) {
      try SnippetRecipeFiles.validatedURL(path, in: directory)
    }
  }

  let layoutURL = directory.appendingPathComponent("layout.asterrecipe")
  try WorkflowRecipeTOML.save(
    WorkflowRecipe(
      name: "layout", scope: .tab, content: .layoutOnly,
      tabs: [WorkflowRecipeTab(title: "A", panes: [WorkflowRecipePane(workingDirectory: "{{current_folder}}")])]),
    to: layoutURL)
  #expect(throws: SnippetRecipeFiles.FileError.notSnippet) { try SnippetRecipeFiles.loadSnippet(at: layoutURL) }
}
