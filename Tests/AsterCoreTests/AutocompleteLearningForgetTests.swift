import Foundation
import Testing

@testable import AsterCore

private var repositoryAutocompleteSpecURL: URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/autocomplete/fig-specs.json")
}

private func makeLearning(_ commands: [String], directory: String = "/project") -> AutocompleteLearningDatabase {
  var database = AutocompleteLearningDatabase()
  for command in commands {
    database.complete(
      command: command, directory: directory, exitStatus: 0, ignorePatterns: [], knownOptions: [],
      sessionIdentifier: "s")
  }
  return database
}

@Test("忘记整行历史会删掉记录，钉住的条目拒删")
func forgetRemovesLearnedLineButKeepsPinned() {
  var database = makeLearning(["git status", "git push"])
  let outcome1 = database.remove(command: "git status", directory: "/project")
  #expect(outcome1)
  #expect(!database.entries.contains { $0.command == "git status" })
  let outcome2 = database.remove(command: "git status", directory: "/project")
  #expect(!outcome2)
  database.pin(command: "git push", directory: "/project")
  let outcome3 = database.remove(command: "git push", directory: "/project")
  #expect(!outcome3)
  #expect(database.entries.contains { $0.command == "git push" })
}

@Test("压制的槽位值不再出现在历史参数与用户词里，再次执行后解除")
func suppressedValuesDisappearUntilUsedAgain() throws {
  let specs = try AutocompleteSpecStore.decode(Data(contentsOf: repositoryAutocompleteSpecURL))
  var database = makeLearning(["git checkout feature-a", "git checkout feature-b", "claude --resume"])
  func arguments() -> [String] {
    database.argumentCandidates(line: "git checkout ", directory: "/project", sessionIdentifier: "s", specDatabase: specs)
      .map(\.displayText).sorted()
  }
  #expect(arguments() == ["feature-a", "feature-b"])
  let learnedFlags = database.argumentCandidates(
    line: "git checkout ", directory: "/project", sessionIdentifier: "s", specDatabase: specs
  ).map { $0.isLearned }
  #expect(learnedFlags == [true, true])

  let slot = try #require(AutocompleteUsageModel.currentSlot(line: "git checkout ", value: "feature-a", specDatabase: specs))
  let outcome4 = database.suppress(slot: slot, value: "feature-a")
  #expect(outcome4)
  #expect(arguments() == ["feature-b"])
  // 用户词同样过滤：命令名槽位。
  #expect(AutocompleteUsageModel.currentSlot(line: "cla", value: "claude", specDatabase: specs) == AutocompleteUsageModel.commandSlot)
  let outcome5 = database.suppress(slot: AutocompleteUsageModel.commandSlot, value: "claude")
  #expect(outcome5)
  let usage = AutocompleteUsageModel(entries: database.entries, specDatabase: specs, suppressed: database.suppressedValues ?? [:])
  #expect(!usage.learnedValueCandidates(line: "cla", specDatabase: specs).contains { $0.displayText == "claude" })

  // 再跑一次 `git checkout feature-a`：压制自动解除。
  database.unsuppress(slots: AutocompleteUsageModel.slots(of: "git checkout feature-a", specDatabase: specs))
  #expect(arguments() == ["feature-a", "feature-b"])
  #expect(database.isSuppressed(slot: AutocompleteUsageModel.commandSlot, value: "claude"))
}

@Test("没有 suppressedValues 键的旧学习库照常解码；超限的压制表被拒绝")
func suppressedValuesCodableCompatibility() throws {
  let legacy = try AutocompleteLearningStore.encode(makeLearning(["ls"]))
  #expect(!String(decoding: legacy, as: UTF8.self).contains("suppressedValues"))
  let decoded = try AutocompleteLearningStore.decode(legacy)
  #expect(decoded.suppressedValues == nil)

  var database = makeLearning(["ls"])
  let outcome6 = database.suppress(slot: "@command", value: "ls")
  #expect(outcome6)
  let roundTrip = try AutocompleteLearningStore.decode(try AutocompleteLearningStore.encode(database))
  #expect(roundTrip.isSuppressed(slot: "@command", value: "ls"))
  let outcome7 = database.suppress(slot: "@command", value: String(repeating: "x", count: 300))
  #expect(!outcome7)
  let outcome8 = database.suppress(slot: "", value: "x")
  #expect(!outcome8)

  var crowded = AutocompleteLearningDatabase()
  for index in 0..<AutocompleteLearningDatabase.maximumSuppressedSlots {
    let outcome9 = crowded.suppress(slot: "slot\(index)", value: "v")
    #expect(outcome9)
  }
  let outcome10 = crowded.suppress(slot: "one-too-many", value: "v")
  #expect(!outcome10)
  let outcome11 = crowded.suppress(slot: "slot0", value: "another")
  #expect(outcome11)
  // 清空历史时压制表一并清空。
  crowded.clearHistory()
  #expect(crowded.suppressedValues == nil)
}
