// 更新成功时保留较新的内置快照，并保持本地学习状态。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("旧日期的在线快照视为检查成功，不降级 711 条内置规格或本地学习")
@MainActor
func completionServiceDoesNotDowngradeNewerBuiltinDatabase() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/autocomplete/fig-specs.json")
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
  let original = service.specDatabase
  #expect(original.commands.count == 711)
  #expect(original.sourceDate == "2026-10-05")
  #expect(service.submit(command: "tool value", directory: "/project", ignorePatterns: [],
    sessionIdentifier: "pane"))
  #expect(service.pin(command: "make local", directory: "/project"))
  try service.installLocalSpec(.init(name: "private-tool"), learned: true)
  let expectedSpecs = service.specDatabase
  let expectedLearning = service.completionStore.state
  let older = AutocompleteSpecDatabase(sourceRevision: "npm-2.692.3", sourceDate: "2025-05-05",
    commands: (0..<714).map { .init(name: "older-\($0)") })
  let revision = try await service.updateNow(download: { try AutocompleteSpecStore.encode(older) })
  #expect(revision == original.sourceRevision)
  #expect(service.specDatabase == expectedSpecs)
  #expect(service.completionStore.state == expectedLearning)
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/fig-specs.json").path))
  let reloaded = try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
  #expect(reloaded.specDatabase == expectedSpecs)
  #expect(reloaded.completionStore.state == expectedLearning)
}

@Test("没有有效来源日期的更新继续使用既有验证规则", arguments: [nil, "2026-02-30"])
@MainActor
func completionServiceUndatedUpdatesRemainSupported(_ date: String?) throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundled = root.appendingPathComponent("bundled.json")
  let current = AutocompleteSpecDatabase(sourceRevision: "new", sourceDate: "2026-10-05",
    commands: [.init(name: "current")])
  try AutocompleteSpecStore.encode(current).write(to: bundled)
  let service = try AutocompleteService(baseDirectory: root, bundledSpecURL: bundled)
  let incoming = AutocompleteSpecDatabase(sourceRevision: "accepted", sourceDate: date,
    commands: [.init(name: "replacement")])
  try service.applyFigUpdatePayload(AutocompleteSpecStore.encode(incoming), minimumCommandCount: 1)
  #expect(service.specDatabase.sourceRevision == "accepted")
  #expect(service.specDatabase.command(named: "replacement") != nil)
}
