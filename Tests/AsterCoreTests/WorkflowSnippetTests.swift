import Foundation
import Testing

@testable import AsterCore

// 命令片段：`.commands` Recipe 的 tags 字段（TOML 往返、旧格式兼容、校验）与 WorkflowSnippet 规则。

@Test("片段标签随 TOML 往返；没有标签时不写 tags 键，旧版本仍能读取")
func workflowRecipeTagsRoundTripAndStayOptional() throws {
  let tagged = WorkflowRecipe(
    name: "重启服务", scope: .commands, content: .includeCommands,
    commands: ["sudo systemctl restart api", "journalctl -u api -n 50"], tags: ["prod", "api"])
  let data = try WorkflowRecipeTOML.encode(tagged)
  #expect(String(decoding: data, as: UTF8.self).contains(#"tags = ["prod", "api"]"#))
  #expect(try WorkflowRecipeTOML.decode(data, source: .savedRecipe).recipe == tagged)

  var plain = tagged
  plain.tags = []
  let plainText = String(decoding: try WorkflowRecipeTOML.encode(plain), as: UTF8.self)
  #expect(!plainText.contains("tags"))

  // 旧文件没有 tags 键。
  let legacy = """
    [recipe]
    name = "ls"
    version = 1
    scope = "commands"
    commands = ["ls -la"]
    """
  #expect(try WorkflowRecipeTOML.decode(Data(legacy.utf8), source: .recipeFile).recipe.tags.isEmpty)
}

@Test("标签只属于命令片段；数量、长度、逗号与控制字符受限；重复 tags 键被拒")
func workflowRecipeTagsAreValidated() throws {
  let base = WorkflowRecipe(name: "x", scope: .commands, content: .includeCommands, commands: ["ls"])
  var tooMany = base
  tooMany.tags = (0...WorkflowRecipeTOML.maximumTags).map { "t\($0)" }
  var tooLong = base
  tooLong.tags = [String(repeating: "x", count: WorkflowRecipeTOML.maximumTagBytes + 1)]
  var comma = base
  comma.tags = ["a,b"]
  var control = base
  control.tags = ["a\u{1}"]
  var empty = base
  empty.tags = [""]
  for recipe in [tooMany, tooLong, comma, control, empty] {
    #expect(throws: WorkflowRecipeTOMLError.self) { try WorkflowRecipeTOML.validate(recipe) }
  }

  let layout = """
    [recipe]
    name = "tab"
    version = 1
    scope = "tab"
    tags = ["prod"]

    [[window.tabs]]
    title = "A"

    [[window.tabs.panes]]
    cwd = "{{current_folder}}"
    """
  #expect(throws: WorkflowRecipeTOMLError.invalidStructure) {
    try WorkflowRecipeTOML.decode(Data(layout.utf8), source: .recipeFile)
  }
  let duplicate = """
    [recipe]
    name = "ls"
    version = 1
    scope = "commands"
    commands = ["ls"]
    tags = ["a"]
    tags = ["b"]
    """
  #expect(throws: WorkflowRecipeTOMLError.duplicateKey("tags", line: 7)) {
    try WorkflowRecipeTOML.decode(Data(duplicate.utf8), source: .recipeFile)
  }
}

@Test("Recipe 的 JSON 解码在缺少 tags 时补空数组")
func workflowRecipeJSONDecodesWithoutTags() throws {
  let recipe = WorkflowRecipe(name: "ls", scope: .commands, content: .includeCommands, commands: ["ls"], tags: ["a"])
  var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
  #expect(object["tags"] as? [String] == ["a"])
  object.removeValue(forKey: "tags")
  let decoded = try JSONDecoder().decode(WorkflowRecipe.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(decoded.tags.isEmpty)
  #expect(decoded.commands == ["ls"])
}

@Test("片段表单：命令一行一条、丢空行；标签中英文逗号分隔并去重；名称去空白")
func workflowSnippetMakeNormalizesFields() throws {
  let recipe = try WorkflowSnippet.make(
    name: "  部署  ", commandsText: "\n  cd ~/app\n\n make deploy \n   \n", tagsText: "prod， Prod, web,,")
  #expect(recipe.name == "部署")
  #expect(recipe.scope == .commands)
  #expect(recipe.commands == ["  cd ~/app", " make deploy "])
  #expect(recipe.tags == ["prod", "web"])
  #expect(WorkflowSnippet.pasteText(recipe) == "  cd ~/app\n make deploy ")

  #expect(throws: WorkflowRecipeTOMLError.invalidStructure) {
    try WorkflowSnippet.make(name: "空", commandsText: " \n ", tagsText: "")
  }
  #expect(throws: WorkflowRecipeTOMLError.missingValue("recipe.name")) {
    try WorkflowSnippet.make(name: "  ", commandsText: "ls", tagsText: "")
  }
}

@Test("片段标签与主机标签按不分大小写的交集计分；文件名只留安全字符")
func workflowSnippetTagOverlapAndFileStem() {
  #expect(WorkflowSnippet.tagOverlap(snippetTags: ["Prod", "db"], hostTags: ["prod", "DB", "eu"]) == 2)
  #expect(WorkflowSnippet.tagOverlap(snippetTags: ["web"], hostTags: []) == 0)
  #expect(WorkflowSnippet.fileStem(for: "Restart api / prod") == "Restart-api-prod")
  #expect(WorkflowSnippet.fileStem(for: "重启") == "snippet")
}
