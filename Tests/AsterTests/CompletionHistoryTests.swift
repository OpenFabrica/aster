// 根据 Otty 原生 record、frecency 和 cleanup_if_failed 恢复的规则验证。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("首词与子命令参数使用独立上下文，seen bonus 不跨应用启动")
@MainActor
func completionHistorySeparatesCommandAndArgumentContexts() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try historyTestService(root)
  try service.installLocalSpec(.init(name: "ship", subcommands: [.init(name: "deploy")]), learned: true)
  #expect(service.record(command: "ship deploy app --tag=next", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  #expect(service.completionStore.state.history.contains { $0.command == "" && $0.token == "ship" })
  #expect(service.completionStore.state.history.contains { $0.command == "ship deploy" && $0.token == "app" })
  #expect(service.completionStore.state.history.contains { $0.command == "ship deploy" && $0.token == "--tag=next" })
  #expect(service.seenTokens.contains("ship deploy\tapp"))
  #expect(try historyTestService(root).seenTokens.isEmpty)
  try service.clearData(selection: .history)
  #expect(service.seenTokens.isEmpty)
}

@Test("相对命令首词按目录隔离，前导 ASCII 空格命令不记录")
@MainActor
func completionHistoryScopesRelativeCommandsAndSkipsLeadingSpace() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try historyTestService(root)
  for directory in ["/one", "/two"] {
    #expect(service.record(command: "./tool value", directory: directory, exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  }
  let contexts = service.completionStore.state.history.filter { $0.token == "./tool" }.map(\.command)
  #expect(Set(contexts) == ["\u{0}cwd:/one", "\u{0}cwd:/two"])
  let before = service.completionStore.state
  #expect(!service.record(command: " ignored value", directory: "/one", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  #expect(service.completionStore.state == before)
}

@Test("127 删除指定目录整行和非选项词频，保留其他目录整行与选项词频")
@MainActor
func completionHistoryCommandNotFoundCleanupUsesExactKeys() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try historyTestService(root)
  let command = "uninstalled-cli --flag value"
  for directory in ["/one", "/two"] {
    #expect(service.record(command: command, directory: directory, exitStatus: 0,
      ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  }
  #expect(!service.record(command: command, directory: "/one", exitStatus: 127,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  #expect(service.completionStore.state.fullLines.map(\.directory) == ["/two"])
  #expect(!service.completionStore.state.history.contains { $0.token == "uninstalled-cli" || $0.token == "value" })
  #expect(service.completionStore.state.history.contains { $0.command == "uninstalled-cli" && $0.token == "--flag" })
  #expect(!service.seenTokens.contains("uninstalled-cli\tvalue"))
  #expect(!service.seenTokens.contains("\tuninstalled-cli"))
  #expect(try historyTestService(root).completionStore.state == service.completionStore.state)
}

@Test("其他失败仅删除未知长选项，用等号前名称检查并保留短选项和整行")
@MainActor
func completionHistoryFailureRemovesOnlyUnknownLongOptions() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try historyTestService(root)
  let command = "testcmd --known=value --unknown=value -x -- argument"
  #expect(service.record(command: command, directory: "/project", exitStatus: 2,
    ignorePatterns: [], knownOptions: ["--known"], sessionIdentifier: "session"))
  let values = Set(service.completionStore.state.history.filter { $0.command == "testcmd" }.map(\.token))
  #expect(values.contains("--known=value"))
  #expect(!values.contains("--unknown=value"))
  #expect(values.contains("-x") && values.contains("--") && values.contains("argument"))
  #expect(service.completionStore.state.fullLines.first?.command == command)
  #expect(!service.seenTokens.contains("testcmd\t--unknown=value"))
  #expect(service.record(command: "unrecognized --still-learned", directory: "/project", exitStatus: 1,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  #expect(service.completionStore.state.history.contains { $0.token == "--still-learned" })
}

@MainActor
private func historyTestService(_ root: URL) throws -> AutocompleteService {
  let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/autocomplete/fig-specs.json")
  return try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
}
