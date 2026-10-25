// 提交即学习、结束时清理；按会话身份隔离待处理的命令。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("提交后运行中即可供其他 Pane 查询，成功结束不重复计数")
@MainActor
func completionLifecyclePublishesBeforeCommandFinishes() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try lifecycleTestService(root)
  #expect(service.submit(command: "tool deploy", directory: "/project", ignorePatterns: [], sessionIdentifier: "one"))
  let result = service.suggestions(line: "tool d", directory: "/project", sessionIdentifier: "two",
    controls: ControlConfiguration())
  #expect(result.candidates.contains { $0.insertText == "tool deploy" })
  let recorded = service.completionStore.state
  #expect(service.commandFinished(exitStatus: 0, sessionIdentifier: "one"))
  #expect(service.completionStore.state == recorded)
  #expect(!service.commandFinished(exitStatus: 127, sessionIdentifier: "one"))
  #expect(service.completionStore.state == recorded)
}

@Test("关闭学习不产生词频、整行或结束事件清理")
@MainActor
func completionLifecycleDisabledLearningDoesNotCreatePending() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try lifecycleTestService(root)
  #expect(!service.submit(command: "tool deploy", directory: "/project", ignorePatterns: [],
    sessionIdentifier: "one", learningEnabled: false))
  #expect(!service.commandFinished(exitStatus: 127, sessionIdentifier: "one"))
  #expect(service.completionStore.state == CompletionLearningState())
  #expect(service.seenTokens.isEmpty)
}

@Test("会话结束事件只清理自己的 pending，取消不撤销已记录历史")
@MainActor
func completionLifecycleIsolatesPendingBySession() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try lifecycleTestService(root)
  #expect(service.submit(command: "alpha one", directory: "/project", ignorePatterns: [], sessionIdentifier: "one"))
  #expect(service.submit(command: "beta two", directory: "/project", ignorePatterns: [], sessionIdentifier: "two"))
  #expect(service.commandFinished(exitStatus: 127, sessionIdentifier: "one"))
  #expect(service.completionStore.state.fullLines.map(\.command) == ["beta two"])
  #expect(service.completionStore.state.history.contains { $0.token == "beta" })
  #expect(service.commandFinished(exitStatus: 0, sessionIdentifier: "two"))
  #expect(service.submit(command: "gamma three", directory: "/project", ignorePatterns: [], sessionIdentifier: "three"))
  service.cancelPending(sessionIdentifier: "three")
  #expect(!service.commandFinished(exitStatus: 127, sessionIdentifier: "three"))
  #expect(service.completionStore.state.fullLines.contains { $0.command == "gamma three" })
}

@Test("整行长度和空目录限制不阻止词频记录")
@MainActor
func completionLifecycleAppliesFullLineLimitsSeparately() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try lifecycleTestService(root)
  let longValue = String(repeating: "字", count: 2_044)
  #expect(service.submit(command: "tool " + longValue, directory: "/project", ignorePatterns: [], sessionIdentifier: "one"))
  #expect(service.completionStore.state.fullLines.isEmpty)
  #expect(service.completionStore.state.history.contains { $0.token == longValue })
  #expect(service.submit(command: "remote value", directory: "", ignorePatterns: [], sessionIdentifier: "two"))
  #expect(service.completionStore.state.fullLines.isEmpty)
  #expect(service.completionStore.state.history.contains { $0.token == "remote" })
  #expect(service.submit(command: "\ttool short   ", directory: "/project", ignorePatterns: [], sessionIdentifier: "three"))
  #expect(service.completionStore.state.fullLines.first?.command == "\ttool short")
}

@Test("skipSecrets只阻止新整行，词频独立跳过秘密值且旧整行保留")
@MainActor
func completionLifecycleSecretSwitchIsProspectiveAndFullLineOnly() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try lifecycleTestService(root)
  #expect(service.submit(command: "tool --token synthetic-one", directory: "/project", ignorePatterns: [],
    sessionIdentifier: "one", skipSecrets: false))
  #expect(service.submit(command: "tool --token synthetic-two", directory: "/project", ignorePatterns: [],
    sessionIdentifier: "two", skipSecrets: true))
  #expect(service.completionStore.state.fullLines.map(\.command) == ["tool --token synthetic-one"])
  #expect(!service.completionStore.state.history.contains { $0.token.hasPrefix("synthetic-") })
  #expect(service.completionStore.state.history.contains { $0.token == "--token" })
}

@Test("失败选项判断包含兄弟子命令定义的名称")
@MainActor
func completionLifecycleKnownFlagsTraverseWholeRootSpec() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try lifecycleTestService(root)
  try service.installLocalSpec(.init(name: "tool", subcommands: [
    .init(name: "one", options: [.init(names: ["--first"])]),
    .init(name: "two", options: [.init(names: ["--second"])]),
  ]), learned: true)
  #expect(service.submit(command: "tool one --second --missing", directory: "/project",
    ignorePatterns: [], sessionIdentifier: "one"))
  #expect(service.commandFinished(exitStatus: 2, sessionIdentifier: "one"))
  #expect(service.completionStore.state.history.contains { $0.command == "tool one" && $0.token == "--second" })
  #expect(!service.completionStore.state.history.contains { $0.token == "--missing" })
}

@MainActor
private func lifecycleTestService(_ root: URL) throws -> AutocompleteService {
  let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/autocomplete/fig-specs.json")
  return try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
}
