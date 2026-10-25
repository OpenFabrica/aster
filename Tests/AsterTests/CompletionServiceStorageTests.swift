// 五类存储与应用服务间的集成边界，不依赖原版未恢复的排序规则。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("清除自动探测不影响显式规格，清除显式规格恢复内置命令")
@MainActor
func completionServiceClearsProbedAndExplicitSpecsIndependently() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundled = completionRepositorySpecs()
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
  let builtinGit = try #require(service.specDatabase.command(named: "git"))
  try service.installLocalSpec(.init(name: "probe-only", options: [.init(names: ["--help"])]))
  try service.installLocalSpec(
    .init(name: "git", subcommands: [.init(name: "private-deploy")]), learned: true)
  #expect(service.specDatabase.command(named: "git")?.subcommands.map(\.name) == ["private-deploy"])
  try service.clearData(selection: .helpProbe)
  #expect(service.specDatabase.command(named: "probe-only") == nil)
  #expect(service.specDatabase.command(named: "git")?.subcommands.map(\.name) == ["private-deploy"])
  let reloaded = try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
  #expect(reloaded.specDatabase.command(named: "git")?.subcommands.map(\.name) == ["private-deploy"])
  try reloaded.clearData(selection: .learnedSpecs)
  #expect(reloaded.specDatabase.command(named: "git") == builtinGit)
}

@Test("清除词频保留整行和目录学习，通用 CLI token 保持不变")
@MainActor
func completionServiceSeparatesTokenAndLineHistory() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: completionRepositorySpecs())
  let token = service.cliToken
  #expect(service.record(
    command: "git status", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  #expect(service.pin(command: "make deploy", directory: "/project"))
  try service.clearData(selection: .history)
  #expect(service.completionStore.state.history.isEmpty)
  #expect(service.completionStore.state.fullLines.map(\.command) == ["git status"])
  #expect(service.isPinned(command: "make deploy", directory: "/project"))
  try service.clearData(selection: .fullLines)
  #expect(service.isPinned(command: "make deploy", directory: "/project"))
  try service.clearData(selection: .learnedFolder)
  #expect(!service.isPinned(command: "make deploy", directory: "/project"))
  #expect(try String(contentsOf: root.appendingPathComponent("cli-token"), encoding: .utf8) == token)
}

@Test("显式学习保留原命令，过滤设置由记录入口控制")
@MainActor
func completionServiceExplicitLearningRetainsCommand() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: completionRepositorySpecs())
  #expect(service.pin(command: "testcli --token synthetic-test-value", directory: "/project"))
  #expect(service.completionStore.state.learnedFolder.first?.command == "testcli --token synthetic-test-value")
  #expect(!service.record(command: "skip-this test", directory: "/project", exitStatus: 0,
    ignorePatterns: ["skip-*"], knownOptions: [], sessionIdentifier: "session"))
  #expect(service.completionStore.state.fullLines.isEmpty)
}

@Test("并发更新共享下载；坏响应后允许重试且保留原规格")
@MainActor
func completionServiceUpdateSingleFlightAndRetry() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: completionRepositorySpecs())
  let original = service.specDatabase
  let gate = AsyncStream<Void>.makeStream()
  var attempts = 0
  let download: @MainActor () async throws -> Data = {
    attempts += 1
    for await _ in gate.stream { break }
    return Data("invalid update".utf8)
  }
  let first = Task { try await service.updateNow(download: download) }
  while attempts == 0 { await Task.yield() }
  let second = Task { try await service.updateNow(download: download) }
  // 让第二个调用进入 service，在第一个下载仍挂起时复用它。
  await Task.yield()
  await Task.yield()
  gate.continuation.yield(())
  gate.continuation.finish()
  await #expect(throws: (any Error).self) { try await first.value }
  await #expect(throws: (any Error).self) { try await second.value }
  #expect(attempts == 1)
  #expect(service.specDatabase == original)
  let update = AutocompleteSpecDatabase(sourceRevision: "retry", commands: (0..<100).map {
    AutocompleteCommandSpec(name: "test-command-\($0)")
  })
  let revision = try await service.updateNow(download: {
    attempts += 1
    return try AutocompleteSpecStore.encode(update)
  })
  #expect(attempts == 2)
  #expect(revision == "retry")
}

private func completionRepositorySpecs() -> URL {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/autocomplete/fig-specs.json")
}

@Test("重复记录保存衰减分加一，token 与整行使用同一原生公式")
@MainActor
func completionServiceStoresDecayedScoreOnRepeat() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: completionRepositorySpecs())
  let start = Date(timeIntervalSince1970: 1_000_000)
  for date in [start, start.addingTimeInterval(3_600)] {
    #expect(service.record(command: "testcmd value", directory: "/project", exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "session", at: date))
  }
  let line = try #require(service.completionStore.state.fullLines.first)
  let token = try #require(service.completionStore.state.history.first { $0.token == "value" })
  #expect(abs(line.score - 1.95) < 0.000_001)
  #expect(abs(token.score - 1.95) < 0.000_001)
  #expect(line.count == 2 && token.count == 2)
  let reloaded = try CompletionStore(baseDirectory: root)
  #expect(reloaded.state.fullLines.first?.score == line.score)
}

@Test("清空已空的自动探测库仍使在途请求失效，其它类别不改变代次")
@MainActor
func completionServiceInvalidatesProbeGenerationOnEmptyClear() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: completionRepositorySpecs())
  #expect(service.helpProbeGeneration == 0)
  try service.clearData(selection: [.history, .fullLines, .learnedFolder, .learnedSpecs])
  #expect(service.helpProbeGeneration == 0)
  try service.clearData(selection: .helpProbe)
  #expect(service.helpProbeGeneration == 1)
  try service.clearData(selection: .helpProbe)
  #expect(service.helpProbeGeneration == 2)
  try service.clearData(selection: .fullLines)
  #expect(service.helpProbeGeneration == 2)
}

@Test("同一秒重复提交直接加一，token 和整行的持久化时间没有亚秒排序差异")
@MainActor
func completionServiceStoresWholeUnixSeconds() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: completionRepositorySpecs())
  for seconds in [1_000.1, 1_000.9] {
    #expect(service.record(command: "tool value", directory: "/project", exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "pane",
      at: Date(timeIntervalSince1970: seconds)))
  }
  let state = try CompletionStore(baseDirectory: root).state
  #expect(state.history.count == 2 && state.fullLines.count == 1)
  #expect(state.history.allSatisfy { $0.score == 2 && $0.lastUsed.timeIntervalSince1970 == 1_000 })
  #expect(state.fullLines.allSatisfy { $0.score == 2 && $0.lastUsed.timeIntervalSince1970 == 1_000 })
}
