// 原版发布快照的数据边界：711 条公开 Fig 规格与安全 scoped package 命令名。
import Foundation
import Testing

@testable import AsterCore

@Test("发行 Fig 快照保留711条上游规格、日期和两个scoped package入口")
func figSnapshotMatchesRecoveredMetadata() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let data = try Data(contentsOf: root.appendingPathComponent("Resources/autocomplete/fig-specs.json"))
  let database = try AutocompleteSpecStore.decode(data)
  #expect(database.commands.count == 711)
  #expect(database.sourceDate == "2026-10-05")
  #expect(database.sourceRevision == "aef52acff84c")
  #expect(database.command(named: "@commercelayer/cli") != nil)
  #expect(database.command(named: "@forge/cli") != nil)
  func hasOverlay(_ command: AutocompleteCommandSpec) -> Bool {
    !command.description.chinese.isEmpty || command.subcommands.contains(where: hasOverlay)
  }
  #expect(!database.commands.contains(where: hasOverlay))
}

@Test("发行 Fig 快照不再丢弃字面名称或截断静态候选列表")
func figSnapshotRetainsEveryStaticNode() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let data = try Data(contentsOf: root.appendingPathComponent("Resources/autocomplete/fig-specs.json"))
  let database = try AutocompleteSpecStore.decode(data)
  var commands = 0, options = 0, arguments = 0, suggestions = 0
  func count(_ command: AutocompleteCommandSpec) {
    commands += 1
    options += command.options.count
    let args = command.arguments + command.options.flatMap(\.args)
    arguments += args.count
    suggestions += args.reduce(0) { $0 + $1.suggestions.count }
    command.subcommands.forEach(count)
  }
  database.commands.forEach(count)
  #expect(commands == 17_517)
  #expect(options == 67_994)
  #expect(arguments == 40_173)
  #expect(suggestions == 40_435)
  let pip = try #require(database.command(named: "pip")?.subcommand(named: "install"))
  #expect(pip.arguments.first?.suggestions.count == 4_004)
  let curl = try #require(database.command(named: "curl")?.option(named: "-H"))
  #expect(curl.args.first?.suggestions.contains { $0.name == "Content-Type: application/json" } == true)
  #expect(database.command(named: "aws")?.subcommand(named: "codecommit")?.description.english.utf8.count == 9_962)
}

@Test("顶级命令名仅增加安全scope/name形式，不放宽路径和shell字符")
func figScopedCommandNamesRejectPathsAndMetacharacters() throws {
  for name in ["@commercelayer/cli", "@forge/cli"] {
    let database = AutocompleteSpecDatabase(sourceRevision: "fixture", commands: [.init(name: name)])
    #expect(try AutocompleteSpecStore.decode(AutocompleteSpecStore.encode(database)).commands.first?.name == name)
  }
  for name in ["../cli", "/bin/sh", "@scope/../cli", "@scope//cli", "@scope/", "@/cli", "@scope/..", "@scope/cli;echo"] {
    let database = AutocompleteSpecDatabase(sourceRevision: "fixture", commands: [.init(name: name)])
    #expect(throws: AutocompleteStoreError.invalidData) { try AutocompleteSpecStore.encode(database) }
  }
}
