// 词频跨目录复用；整行历史按目录保存；上一个命令不额外改变候选排序。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Test("全局命令词频可以影响其它目录排序，但不让多个命令名自动预览")
@MainActor
func usageRankingPrefersGloballyUsedCommandName() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  for _ in 0..<3 {
    #expect(service.record(
      command: "git status", directory: root.appendingPathComponent("other").path,
      exitStatus: 0, ignorePatterns: [], knownOptions: [], sessionIdentifier: "s"))
  }
  let result = service.suggestions(
    line: "gi", directory: root.appendingPathComponent("fresh").path,
    sessionIdentifier: "s", controls: .init())
  let first = try #require(result.candidates.first)
  #expect(first.insertText == "git")
  #expect(first.kind == .command)
  #expect((first.historyScore ?? 0) > 0)
  #expect(result.candidates.count > 1)
  #expect(!CompletionPresentation.leaderIsClear(result.candidates))
}

@Test("识别过的子命令不额外记录词频，静态候选保留原顺序")
@MainActor
func usageRankingKeepsKnownSubcommandOrder() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let fresh = root.appendingPathComponent("fresh").path
  let before = service.suggestions(
    line: "git ch", directory: fresh, sessionIdentifier: "s", controls: .init())
  #expect(before.candidates.map(\.insertText) == ["checkout", "cherry-pick"])
  for hash in ["a1", "b2"] {
    #expect(service.record(
      command: "git cherry-pick \(hash)", directory: root.appendingPathComponent("other").path,
      exitStatus: 0, ignorePatterns: [], knownOptions: [], sessionIdentifier: "s"))
  }
  let after = service.suggestions(
    line: "git ch", directory: fresh, sessionIdentifier: "s", controls: .init())
  #expect(after.candidates.map(\.insertText) == before.candidates.map(\.insertText))
  #expect(!service.completionStore.state.history.contains { $0.token == "cherry-pick" })
  #expect(service.completionStore.state.history.contains { $0.command == "git cherry-pick" && $0.token == "a1" })
  #expect(after.candidates.first?.clearLeader == false)
  #expect(!CompletionPresentation.leaderIsClear(after.candidates))
}

@Test("无规格命令的参数词频跨目录复用，并按命令上下文隔离")
@MainActor
func usageRankingOffersGlobalArgumentValuesForUnknownCommands() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let other = root.appendingPathComponent("other").path
  for command in ["zzhistorytool alpha", "zzhistorytool beta", "zzotherhistorytool aardvark"] {
    #expect(service.record(command: command, directory: other, exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "s"))
  }
  let fresh = root.appendingPathComponent("fresh").path
  func query(_ line: String) -> AutocompleteResult {
    service.suggestions(line: line, directory: fresh, sessionIdentifier: "s", controls: .init())
  }
  #expect(query("zzhistorytool a").candidates.contains { $0.displayText == "alpha" })
  #expect(query("zzhistorytool b").candidates.contains { $0.displayText == "beta" })
  #expect(!query("zzhistorytool a").candidates.contains { $0.displayText == "aardvark" })
  #expect(query("zzotherhistorytool a").candidates.contains { $0.displayText == "aardvark" })
  #expect(!query("zzotherhistorytool a").candidates.contains { $0.displayText == "alpha" })
  #expect(!query("zzhistorytool a").candidates.contains { $0.kind == .learnedCommand })
}

@Test("会话上一条命令不同也使用相同历史排序，不产生命令转移加分")
@MainActor
func usageRankingDoesNotUsePreviousCommandContext() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let project = root.appendingPathComponent("project").path
  for _ in 0..<3 {
    #expect(service.record(command: "git add .", directory: project, exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "after-add"))
    #expect(service.record(command: "git commit -m wip", directory: project, exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "after-commit"))
  }
  let stored = service.completionStore.state
  let afterAdd = service.suggestions(
    line: "git ", directory: project, sessionIdentifier: "after-add", controls: .init())
  let afterCommit = service.suggestions(
    line: "git ", directory: project, sessionIdentifier: "after-commit", controls: .init())
  #expect(afterAdd.candidates.map(\.insertText) == afterCommit.candidates.map(\.insertText))
  #expect(afterAdd.candidates.map(\.kind) == afterCommit.candidates.map(\.kind))
  #expect(afterAdd.ghostText == afterCommit.ghostText)
  #expect(service.completionStore.state == stored)
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state/transitions.json").path))
}

@Test("清除词频与整行历史分别生效，重载后保留对应结果")
@MainActor
func usageRankingClearsHistoryAndFullLinesIndependently() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let project = root.appendingPathComponent("project").path
  #expect(service.record(command: "git cherry-pick a1", directory: project, exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "s"))
  #expect(!service.completionStore.state.history.isEmpty)
  try service.clearData(selection: .history)
  #expect(service.completionStore.state.history.isEmpty)
  #expect(service.completionStore.state.fullLines.map(\.command) == ["git cherry-pick a1"])
  #expect(service.suggestions(line: "git ch", directory: project, sessionIdentifier: "s", controls: .init())
    .candidates.contains { $0.kind == .learnedCommand && $0.insertText == "git cherry-pick a1" })

  try service.clearData(selection: .fullLines)
  let reloaded = try makeUsageRankingService(root)
  #expect(reloaded.completionStore.state.history.isEmpty)
  #expect(reloaded.completionStore.state.fullLines.isEmpty)
  let result = reloaded.suggestions(line: "git ch", directory: project, sessionIdentifier: "s", controls: .init())
  #expect(result.candidates.map(\.insertText) == ["checkout", "cherry-pick"])
}

@Test("提交拒绝空行、前导空格和控制字符，并保留合法命令名称")
@MainActor
func usageRankingRejectsInvalidSubmission() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  func record(_ command: String) -> Bool {
    service.record(command: command, directory: root.path, exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "s")
  }
  #expect(!record(""))
  #expect(!record(" ls -la"))
  #expect(!record("ls\nwhoami"))
  #expect(!record("\u{1B}[0mwhoami"))
  #expect(record("ls -la"))
  #expect(record("7z x archive.7z"))
  #expect(record("2to3 script.py"))
  #expect(Set(service.completionStore.state.fullLines.map(\.command)) == ["ls -la", "7z x archive.7z", "2to3 script.py"])
}

@MainActor
private func makeUsageRankingService(_ root: URL) throws -> AutocompleteService {
  try AutocompleteService(
    baseDirectory: root.appendingPathComponent("state", isDirectory: true),
    bundledSpecURL: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/autocomplete/fig-specs.json"))
}

private func makeUsageRankingDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-usage-ranking-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
