import Foundation
import Testing

@testable import AsterCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// 带使用统计的整行历史候选；`daysAgo` 是最后使用距今的天数。
private func history(_ command: String, score: Double = 400, uses: Int, daysAgo: Double) -> AutocompleteCandidate {
  AutocompleteCandidate(
    insertText: command, kind: .learnedCommand, score: score, replacement: .fullLine, isLearned: true,
    historyUsage: AutocompleteHistoryUsage(useCount: uses, lastUsedAt: now.addingTimeInterval(-daysAgo * 86_400)))
}

/// 相关分（去掉基础权重后）为 `relevance` 的子命令候选。
private func subcommand(_ name: String, relevance: Double) -> AutocompleteCandidate {
  AutocompleteCandidate(
    insertText: name, kind: .subcommand,
    score: AutocompleteRelevance.baseWeight(for: .subcommand) + relevance,
    replacement: .currentToken(start: 4))
}

@Test("只有一个候选时首项恒为明显领先，没有候选时不领先")
func inlineLeadSingleCandidate() {
  #expect(AutocompleteInlineLead.leaderIsClear([subcommand("checkout", relevance: 1)]))
  #expect(!AutocompleteInlineLead.leaderIsClear([]))
}

@Test("整行历史用得更多且最近用过才明显领先")
func inlineLeadHistoryNeedsMoreUsesAndMostRecent() {
  let rival = history("git commit --amend", uses: 2, daysAgo: 3)
  #expect(AutocompleteInlineLead.leaderIsClear([history("git commit -m wip", uses: 3, daysAgo: 0), rival]))
  // 次数相同：谁也不领先（对应 Otty 的 +0.5 分差）。
  #expect(!AutocompleteInlineLead.leaderIsClear([history("git commit -m wip", uses: 2, daysAgo: 0), rival]))
  // 用得更多但不是最近用过的那条：不领先。
  #expect(!AutocompleteInlineLead.leaderIsClear([history("git commit -m wip", uses: 5, daysAgo: 7), rival]))
}

@Test("首项历史只和其它历史比，规格候选不影响判定")
func inlineLeadHistoryIgnoresSpecCandidates() {
  let candidates = [
    history("git commit -m wip", uses: 1, daysAgo: 0),
    subcommand("commit", relevance: 300),
  ]
  #expect(AutocompleteInlineLead.leaderIsClear(candidates))
}

@Test("缺少使用统计的历史无法比较，按不领先处理")
func inlineLeadHistoryWithoutUsageIsNotClear() {
  let bare = AutocompleteCandidate(insertText: "git status", kind: .learnedCommand, score: 500, replacement: .fullLine)
  #expect(!AutocompleteInlineLead.leaderIsClear([bare, history("git stash", uses: 1, daysAgo: 1)]))
  #expect(!AutocompleteInlineLead.leaderIsClear([history("git status", uses: 9, daysAgo: 0), bare]))
}

@Test("非历史首项的相关分至少是次项的 1.5 倍才明显领先")
func inlineLeadSpecNeedsRelevanceRatio() {
  // `git ch`：checkout 与 cherry-pick 只差匹配度（137.5 对 130），不领先。
  #expect(!AutocompleteInlineLead.leaderIsClear([
    subcommand("checkout", relevance: 137.5), subcommand("cherry-pick", relevance: 130),
  ]))
  // checkout 在本目录用过几次后拿到使用加成，领先到 1.5 倍以上。
  #expect(AutocompleteInlineLead.leaderIsClear([
    subcommand("checkout", relevance: 203.4), subcommand("cherry-pick", relevance: 130),
  ]))
  // 正好 1.5 倍算领先。
  #expect(AutocompleteInlineLead.leaderIsClear([
    subcommand("checkout", relevance: 195), subcommand("cherry-pick", relevance: 130),
  ]))
}

@Test("比较前先减去基础权重，不同类型的候选不因基础分差异被判领先")
func inlineLeadSubtractsBaseWeight() {
  // 子命令基础分 165、文件 100：总分差 65，相关分相同，不领先。
  let file = AutocompleteCandidate(
    insertText: "checkout.txt", kind: .file,
    score: AutocompleteRelevance.baseWeight(for: .file) + 130, replacement: .currentToken(start: 4))
  #expect(!AutocompleteInlineLead.leaderIsClear([subcommand("checkout", relevance: 130), file]))
}

@Test("非历史首项只和其它非历史候选比；其余全是历史时首项领先")
func inlineLeadSpecIgnoresHistoryRunnerUp() {
  let candidates = [
    subcommand("checkout", relevance: 140),
    history("git cherry-pick abc", score: 300, uses: 9, daysAgo: 0),
  ]
  #expect(AutocompleteInlineLead.leaderIsClear(candidates))
}

@Test("引擎生成的整行历史带上学习库的使用次数与最后使用时间")
func inlineLeadEngineCarriesHistoryUsage() throws {
  let lastUsed = now.addingTimeInterval(-60)
  let engine = AutocompleteEngine(specDatabase: AutocompleteSpecDatabase(sourceRevision: "test", commands: []))
  let result = engine.suggestions(
    for: AutocompleteQuery(line: "make ", directory: "/tmp"),
    learned: [AutocompleteLearnedSuggestion(command: "make test", score: 1, useCount: 4, lastUsedAt: lastUsed)],
    pinned: [], readmeCommands: [])
  let candidate = try #require(result.candidates.first)
  #expect(candidate.historyUsage == AutocompleteHistoryUsage(useCount: 4, lastUsedAt: lastUsed))
}
