// 原生静态 Fig 路径恢复规则：完整字面数据、精确上下文、Unicode 前缀与祖先选项。
import Foundation
import Testing

@testable import AsterCore

@Test("Fig 上下文精确匹配选项，按声明参数数量跳过，未知选项不终止后续解析")
func figContextConsumesOnlyExactOptionNames() {
  let root = AutocompleteCommandSpec(name: "tool", subcommands: [.init(name: "child")], options: [
    .init(names: ["--value"], args: [.init(name: "value", isOptional: true)]),
    .init(names: ["--pair"], args: [.init(name: "one", isVariadic: true), .init(name: "two")]),
    .init(names: ["-"], args: [.init(name: "value")]),
  ])
  for option in ["--", "--VALUE", "--value=literal", "-ab"] {
    #expect(FigCompletionContext(root: root, completed: [option, "child"]).command.name == "child")
  }
  #expect(FigCompletionContext(root: root, completed: ["--value", "child"]).command.name == "tool")
  #expect(FigCompletionContext(root: root, completed: ["--pair", "one", "child"]).command.name == "tool")
  #expect(FigCompletionContext(root: root, completed: ["-", "child"]).command.name == "tool")
}

@Test("Fig 后续子命令可在位置参数之后下钻，并继承祖先选项的参数数量")
func figContextDescendsAfterPositionalsAndUsesAncestorOptions() {
  let root = AutocompleteCommandSpec(name: "tool", subcommands: [
    .init(name: "child", aliases: ["c"], subcommands: [.init(name: "leaf")]),
  ], options: [.init(names: ["--root"], args: [.init(name: "value")])])
  let context = FigCompletionContext(root: root, completed: ["position", "c", "--root", "leaf"])
  #expect(context.command.name == "child")
  #expect(context.commandPath == ["tool", "child"])
  #expect(context.ancestors.map(\.name) == ["tool"])
  #expect(context.positionalCount == 0)
  let next = FigCompletionContext(root: root, completed: ["c", "--root=value", "position", "leaf", "last"])
  #expect(next.command.name == "leaf")
  #expect(next.ancestors.map(\.name) == ["tool", "child"])
  #expect(next.positionalCount == 1)
}

@Test("Fig 选项按当前到根枚举所有名称，不应用旧 hidden 或重复过滤")
func figRulesInheritAllOptionsInNativeOrder() {
  let root = AutocompleteCommandSpec(name: "root", options: [.init(names: ["--root"], description: "root")])
  let parent = AutocompleteCommandSpec(name: "parent", options: [.init(names: ["--shared"], description: "parent")])
  let child = AutocompleteCommandSpec(name: "child", options: [
    .init(names: ["--shared", "-s"], description: "child", isRepeatable: false, hidden: true),
  ])
  let result = FigCompletionRules.options(of: child, ancestors: [root, parent], prefix: "-")
  #expect(result.map(\.name) == ["--shared", "-s", "--shared", "--root"])
  #expect(result.map(\.description) == ["child", "child", "parent", "root"])
  #expect(FigCompletionRules.options(of: child, ancestors: [root, parent], prefix: "--SH")
    .map(\.name) == ["--shared", "--shared"])
}

@Test("Fig 子命令只列主名称，仅精确 hidden 别名隐藏候选")
func figRulesUseHiddenAliasWithoutExpandingAliases() {
  let root = AutocompleteCommandSpec(name: "root", subcommands: [
    .init(name: "Visible", aliases: ["alias-only"], hidden: true),
    .init(name: "secret", aliases: ["hidden"]),
    .init(name: "Mixed", aliases: ["Hidden"]),
  ])
  #expect(FigCompletionRules.subcommands(of: root, prefix: "").map(\.name) == ["Visible", "Mixed"])
  #expect(FigCompletionRules.subcommands(of: root, prefix: "VIS").map(\.name) == ["Visible"])
  #expect(FigCompletionRules.subcommands(of: root, prefix: "alias").isEmpty)
  #expect(FigCompletionContext(root: root, completed: ["alias-only"]).command.name == "Visible")
}

@Test("Fig 合并全部位置参数的静态建议，按 Unicode 小写前缀匹配并保留原文")
func figRulesMergeAllArgumentSuggestionsAsLiterals() {
  let header = AutocompleteSpecItem(name: "Content-Type: application/json", description: "Line one\nLine two")
  let root = AutocompleteCommandSpec(name: "tool", options: [
    .init(names: ["--option"], args: [.init(name: "option", suggestions: [.init(name: "option-only")])]),
  ], arguments: [
    .init(name: "first", suggestions: [header, .init(name: "Äpfel")], isOptional: true),
    .init(name: "second", suggestions: [.init(name: "alias.*"), .init(name: "amqp\t")], isVariadic: true),
  ])
  #expect(FigCompletionRules.suggestions(of: root, prefix: "CONTENT") == [header])
  #expect(FigCompletionRules.suggestions(of: root, prefix: "ä").map(\.name) == ["Äpfel"])
  #expect(FigCompletionRules.suggestions(of: root, prefix: "").map(\.name)
    == ["Content-Type: application/json", "Äpfel", "alias.*", "amqp\t"])
  #expect(FigCompletionRules.suggestions(of: root, prefix: "option").isEmpty)
  #expect(!FigCompletionRules.matches("éclair", prefix: "e\u{301}"))
  #expect(FigCompletionRules.matches("e\u{301}clair", prefix: "e"))
}

@Test("Fig 只对当前命令全部参数的精确模板取并集，含斜杠前缀另外启用路径")
func figRulesUnionTemplatesWithoutArgumentNameHeuristics() {
  var root = AutocompleteCommandSpec(name: "tool", options: [
    .init(names: ["--file"], args: [.init(name: "path", template: ["filepaths"])])
  ], arguments: [.init(name: "file path", template: ["help", "history", "Folders"])])
  #expect(FigCompletionRules.filesystemMode(of: root, prefix: "") == .none)
  #expect(FigCompletionRules.filesystemMode(of: root, prefix: "~") == .none)
  #expect(FigCompletionRules.filesystemMode(of: root, prefix: "./") == .filesAndFolders)
  root.arguments.append(.init(name: "second", template: ["folders"]))
  #expect(FigCompletionRules.filesystemMode(of: root, prefix: "") == .folders)
  root.arguments.append(.init(name: "third", template: ["filepaths"]))
  #expect(FigCompletionRules.filesystemMode(of: root, prefix: "") == .filesAndFolders)
}

@Test("Fig 导入保留完整字面文本与四千项候选，并明确拒绝超出预算的数据")
func figStorePreservesLiteralDataWithinExplicitBudgets() throws {
  let description = "👩‍✈️\n" + String(repeating: "description ", count: 200) + "\0end"
  let argument = AutocompleteArgumentSpec(name: "values", suggestions: (0..<4004).map {
    .init(name: "package-\($0)")
  } + [.init(name: "Content-Type: application/json"), .init(name: "分支 名称"), .init(name: "amqp\t")])
  let command = AutocompleteCommandSpec(name: "tool", description: .init(english: description),
    subcommands: [.init(name: "two words"), .init(name: "")],
    options: [.init(names: [""])], arguments: [argument])
  let database = AutocompleteSpecDatabase(sourceRevision: "fixture", commands: [command])
  #expect(try AutocompleteSpecStore.decode(AutocompleteSpecStore.encode(database)) == database)

  var invalid = database
  invalid.commands[0].description.english = String(repeating: "x", count: AutocompleteSpecStore.maximumDescriptionBytes + 1)
  #expect(throws: AutocompleteStoreError.invalidData) { try AutocompleteSpecStore.encode(invalid) }
  invalid = database
  invalid.commands[0].arguments[0].suggestions = Array(repeating: .init(name: "entry"),
    count: AutocompleteSpecStore.maximumSuggestionsPerArgument + 1)
  #expect(throws: AutocompleteStoreError.invalidData) { try AutocompleteSpecStore.encode(invalid) }
  invalid = database
  invalid.commands[0].subcommands[0].name = "unsafe\ncommand"
  #expect(throws: AutocompleteStoreError.invalidData) { try AutocompleteSpecStore.encode(invalid) }
}
