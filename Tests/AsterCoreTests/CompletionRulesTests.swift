// 来自 Otty 1.6.2 的恢复规则，以及追加输入的边界验证。
import Foundation
import Testing
@testable import AsterCore

private let completionDate = Date(timeIntervalSince1970: 1_700_000_000)

@Test("Otty 词频按小时0.95衰减，负时间归零，最多720小时")
func recoveredCompletionDecayBoundary() {
  let score: (Double) -> Double = { hours in
    CompletionLearningState.frecency(score: 2, lastUsed: completionDate,
      now: completionDate.addingTimeInterval(hours * 3_600))
  }
  #expect(abs(score(1) - 1.9) < 0.000001)
  #expect(score(-1) == 2)
  #expect(score(721) == score(720))
}

@Test("Otty目录整行历史最多20条，并与其他目录隔离")
func recoveredCompletionHistoryBoundAndDirectory() {
  var state = CompletionLearningState()
  state.fullLines = (0..<30).map {
    .init(command: "tool value\($0)", directory: "/a", count: $0 + 1, lastUsed: completionDate)
  }
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: []))
  let result = engine.complete(line: "tool ", directory: "/a", learning: state, now: completionDate)
  #expect(result.candidates.count == 20)
  #expect(result.candidates.first?.insertText == "tool value29")
  #expect(engine.complete(line: "tool ", directory: "/b", learning: state).candidates.isEmpty)
}

@Test("历史首项至少领先0.5且最后使用时间最大，才自动预览")
func recoveredCompletionHistoryLeaderThreshold() {
  func candidate(_ text: String, score: Double, date: Date) -> AutocompleteCandidate {
    .init(insertText: text, kind: .learnedCommand, score: score,
      historyUsage: .init(useCount: 10, lastUsedAt: date))
  }
  let next = candidate("tool next", score: 2, date: completionDate)
  #expect(!CompletionPresentation.leaderIsClear([candidate("tool first", score: 2.49, date: completionDate), next]))
  #expect(CompletionPresentation.leaderIsClear([candidate("tool first", score: 2.5, date: completionDate), next]))
  #expect(!CompletionPresentation.leaderIsClear([
    candidate("tool first", score: 10, date: completionDate.addingTimeInterval(-1)), next]))
}

@Test("原版不拆等号选项值，裸--不终止选项，静态候选取命令args")
func recoveredCompletionOptionArgumentBoundaries() {
  let spec = AutocompleteCommandSpec(name: "tool", options: [
    .init(names: ["--mode"], args: [.init(name: "mode", suggestions: [.init(name: "fast")])])
  ], arguments: [.init(name: "value", suggestions: [.init(name: "final")])])
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [spec]))
  let empty = CompletionLearningState()
  let result = engine.complete(line: "tool --mode=fa", directory: "/", learning: empty)
  #expect(result.candidates.isEmpty)
  let optionValue = engine.complete(line: "tool --mode fi", directory: "/", learning: empty)
  #expect(optionValue.candidates.map(\.displayText) == ["final"])
  let terminated = engine.complete(line: "tool -- fi", directory: "/", learning: empty)
  #expect(terminated.candidates.map(\.displayText) == ["final"])
  #expect(engine.complete(line: "tool -- --m", directory: "/", learning: empty)
    .candidates.map(\.displayText) == ["--mode"])
}

@Test("分号及管道仅在引号外切换命令段，补全不改前面的命令")
func recoveredCompletionKeepsEarlierCommandBytes() {
  #expect(CompletionInput("echo 'a;b' | git chec").segment == "git chec")
  #expect(CompletionInput("echo 'a;b'").segment == "echo 'a;b'")
  let git = AutocompleteCommandSpec(name: "git", subcommands: [.init(name: "checkout")])
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [git]))
  let line = "echo 'a;b' | git chec"
  let result = engine.complete(line: line, directory: "/", learning: .init())
  #expect(result.candidates.first?.resultingLine(from: line) == "echo 'a;b' | git checkout")
  #expect(result.candidates.first?.appendableSuffix(from: line) == "kout")
}

@Test("历史和规格产生同一完整命令时只保留历史一次")
func recoveredCompletionHistoryDeduplicatesSpec() {
  let git = AutocompleteCommandSpec(name: "git", subcommands: [.init(name: "checkout")])
  var state = CompletionLearningState()
  state.fullLines = [.init(command: "git checkout", directory: "/a", lastUsed: completionDate)]
  let result = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [git]))
    .complete(line: "git chec", directory: "/a", learning: state, now: completionDate)
  #expect(result.candidates.count == 1)
  #expect(result.candidates.first?.kind == .learnedCommand)
}

@Test("原版配置别名去Unicode首尾空白、不区分大小写、失败使用原生缺省")
func recoveredCompletionConfigurationAliases() throws {
  #expect(AutocompleteShortcut.parse("\u{2003}RIGHT_ARROW\n") == .rightArrow)
  #expect(AutocompleteShortcut.parse("tab+arrow") == .tabAndRightArrow)
  #expect(AutocompleteShortcut.parse("CTRLSPACE") == .controlSpace)
  #expect(AutocompleteCandidatePanel.parse(" F5 ") == .optionEscape)
  #expect(AutocompleteCandidatePanel.parse("true") == .automatic)
  #expect(AutocompleteCandidatePanel.parse("FALSE") == .disabled)
  #expect(try JSONDecoder().decode(AutocompleteShortcut.self, from: Data("\"invalid\"".utf8)) == .tab)
  #expect(try JSONDecoder().decode(AutocompleteCandidatePanel.self, from: Data("\"invalid\"".utf8)) == .escape)
}

@Test("多个非历史候选只按词频证据判断领先，不把规格基础分当作词频")
func recoveredCompletionNonHistoryLeaderUsesOnlyFrequency() {
  func candidate(_ text: String, frequency: Double?) -> AutocompleteCandidate {
    .init(insertText: text, kind: .argument, score: frequency ?? 0, historyScore: frequency)
  }
  #expect(!CompletionPresentation.leaderIsClear([candidate("a", frequency: nil), candidate("b", frequency: nil)]))
  #expect(CompletionPresentation.leaderIsClear([candidate("a", frequency: 1), candidate("b", frequency: nil)]))
  #expect(!CompletionPresentation.leaderIsClear([candidate("a", frequency: 1.49), candidate("b", frequency: 1)]))
  #expect(CompletionPresentation.leaderIsClear([candidate("a", frequency: 1.5), candidate("b", frequency: 1)]))
}

@Test("空输入及只有空白不返回任何来源的候选")
func recoveredCompletionEmptyInputHasNoCandidates() {
  var state = CompletionLearningState()
  state.fullLines = [.init(command: "tool value", directory: "/a", lastUsed: completionDate)]
  state.learnedFolder = state.fullLines
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [.init(name: "tool")]))
  for line in ["", "  ", "\t"] {
    #expect(engine.complete(line: line, directory: "/a", learning: state,
      readme: ["tool readme"], now: completionDate).candidates.isEmpty)
  }
}

@Test("已知规格按类型排序，选项仅在短横线前缀出现，词频不重写领先标志")
func recoveredCompletionKnownSpecOrderingAndLeader() {
  let spec = AutocompleteCommandSpec(name: "tool", subcommands: [.init(name: "run")],
    options: [.init(names: ["--flag"])], arguments: [.init(name: "value", suggestions: [.init(name: "value")])])
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [spec]))
  let empty = engine.complete(line: "tool ", directory: "/a", learning: .init())
  #expect(empty.candidates.map(\.displayText) == ["run", "value"])
  var state = CompletionLearningState()
  state.history = [.init(command: "tool", token: "value", count: 100, lastUsed: completionDate)]
  let used = engine.complete(line: "tool ", directory: "/a", learning: state, now: completionDate)
  #expect(used.candidates.first?.displayText == "value")
  #expect(!CompletionPresentation.leaderIsClear(used.candidates))
  #expect(engine.complete(line: "tool --", directory: "/a", learning: state)
    .candidates.map(\.displayText) == ["--flag"])
}

@Test("已知规格保留动态来源的描述、显示文本和领先标志")
func recoveredCompletionDynamicItemsKeepNativeFields() {
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [
    .init(name: "git", subcommands: [.init(name: "checkout")])]))
  let result = engine.complete(line: "git checkout f", directory: "/project", learning: .init(), dynamic: [
    .init(name: "feature-one", displayText: "feature-one (remote)", description: "origin", clearLeader: true),
    .init(name: "feature-two"),
  ])
  #expect(result.candidates.map(\.insertText) == ["feature-one", "feature-two"])
  #expect(result.candidates.first?.displayText == "feature-one (remote)")
  #expect(result.candidates.first?.description == "origin")
  #expect(result.candidates.first?.appendableSuffix(from: "git checkout f") == "eature-one")
  #expect(CompletionPresentation.leaderIsClear(result.candidates))
}

@Test("命令名前缀只给现有候选加词频，不凭历史创造程序名")
func recoveredCompletionRootHistoryOnlyBoostsExistingCandidates() {
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [
    .init(name: "tool-a"), .init(name: "tool-b")]))
  var state = CompletionLearningState()
  state.history = [
    .init(command: "", token: "tool-b", count: 2, lastUsed: completionDate),
    .init(command: "", token: "tool-uninstalled", count: 100, lastUsed: completionDate)]
  let result = engine.complete(line: "tool", directory: "/a", learning: state, now: completionDate)
  #expect(result.candidates.map(\.displayText) == ["tool-b", "tool-a"])
  #expect(!CompletionPresentation.leaderIsClear(result.candidates))
}

@Test("本进程见过的token仅查询加10，不改变完整行的分数")
func recoveredCompletionSeenBonusIsTokenOnly() {
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: []))
  var state = CompletionLearningState()
  state.history = [.init(command: "tool", token: "alpha", lastUsed: completionDate),
    .init(command: "tool", token: "beta", count: 5, lastUsed: completionDate)]
  state.fullLines = [.init(command: "tool all", directory: "/a", lastUsed: completionDate)]
  let result = engine.complete(line: "tool ", directory: "/a", learning: state,
    seenTokens: ["tool\talpha"], now: completionDate)
  #expect(result.candidates.first { $0.displayText == "alpha" }?.historyScore == 11)
  #expect(result.candidates.first { $0.kind == .learnedCommand }?.score == 1)
}

@Test("精确整行先占20条名额再删除，不为后继项重算领先标志")
func recoveredCompletionExactHistoryConsumesLimitAndLeader() {
  var state = CompletionLearningState()
  state.fullLines = [.init(command: "tool", directory: "/a", count: 100, lastUsed: completionDate)]
  state.fullLines += (1...25).map { index -> CompletionLearningState.Line in
    .init(command: "tool value\(index)", directory: "/a", count: 30 - index, lastUsed: completionDate)
  }
  let result = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: []))
    .complete(line: "tool", directory: "/a", learning: state, now: completionDate)
  #expect(result.candidates.count == 19)
  #expect(result.candidates.first?.insertText == "tool value1")
  #expect(result.candidates.first?.clearLeader == false)
}

@Test("20条外的最近使用历史也能阻止首项自动领先")
func recoveredCompletionLeaderUsesAllFiveHundredTimestamps() {
  var state = CompletionLearningState()
  state.fullLines = (1...25).map {
    .init(command: "tool value\($0)", directory: "/a", count: 100 - $0,
      lastUsed: completionDate.addingTimeInterval($0 == 25 ? 1 : 0))
  }
  let result = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: []))
    .complete(line: "tool ", directory: "/a", learning: state, now: completionDate)
  #expect(result.candidates.count == 20)
  #expect(result.candidates.first?.clearLeader == false)
}

@Test("已知规格只给已有候选加词频，不混入规格未提供的历史参数")
func recoveredCompletionKnownSpecDoesNotInjectHistoryTokens() {
  let spec = AutocompleteCommandSpec(name: "tool", arguments: [
    .init(name: "value", suggestions: [.init(name: "alpha")])])
  var state = CompletionLearningState()
  state.history = [.init(command: "tool", token: "absent", count: 100, lastUsed: completionDate)]
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: [spec]))
  #expect(engine.complete(line: "tool a", directory: "/a", learning: state).candidates.map(\.displayText) == ["alpha"])
  let unknown = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: []))
  #expect(unknown.complete(line: "tool a", directory: "/a", learning: state).candidates.map(\.displayText) == ["absent"])
}

@Test("历史前缀按SQLite LIKE仅折叠ASCII，百分号下划线与反斜杠按字面匹配")
func recoveredCompletionHistoryPrefixUsesSQLiteLiteralRules() {
  var state = CompletionLearningState()
  state.fullLines = ["GIT status", "Äcmd value", "tool 100%_\\value", "tool 100xxvalue"].map {
    .init(command: $0, directory: "/a", lastUsed: completionDate)
  }
  let engine = CommandCompletionEngine(specifications: .init(sourceRevision: "test", commands: []))
  #expect(engine.complete(line: "git", directory: "/a", learning: state).candidates.map(\.insertText) == ["GIT status"])
  #expect(engine.complete(line: "äcmd", directory: "/a", learning: state).candidates.isEmpty)
  #expect(engine.complete(line: "tool 100%_\\", directory: "/a", learning: state).candidates.map(\.insertText) == ["tool 100%_\\value"])
}
