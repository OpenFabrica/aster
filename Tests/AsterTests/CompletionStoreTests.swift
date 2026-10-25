// 补全新存储的迁移、隔离和原子事务回归。
import AsterCore
import Darwin
import Foundation
import Testing

@testable import Aster

@Test("旧学习仅备份、不导入；重复启动不会重备份或修改 CLI 文件")
func completionStoreBacksUpWithoutImporting() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  for name in CompletionStore.legacyNames {
    try Data("legacy:\(name)".utf8).write(to: root.appendingPathComponent(name))
  }
  let cli = root.appendingPathComponent("cli-token")
  try Data("existing-cli-token".utf8).write(to: cli)
  let requests = root.appendingPathComponent("requests")
  try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: false)
  let request = requests.appendingPathComponent("keep")
  try Data("request".utf8).write(to: request)

  let store = try CompletionStore(baseDirectory: root)
  #expect(store.state == CompletionLearningState())
  let backups = root.appendingPathComponent("backups")
  let entries = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
  #expect(entries.count == 1)
  let backup = try #require(entries.first)
  for name in CompletionStore.legacyNames {
    let original = try Data(contentsOf: root.appendingPathComponent(name))
    #expect(try Data(contentsOf: backup.appendingPathComponent(name)) == original)
  }
  _ = try CompletionStore(baseDirectory: root)
  #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
  #expect(try Data(contentsOf: cli) == Data("existing-cli-token".utf8))
  #expect(try Data(contentsOf: request) == Data("request".utf8))
}

@Test("备份失败不写迁移标记，修复目录后可重试")
func completionStoreRetriesFailedMigration() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let outside = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: outside) }
  try Data("legacy".utf8).write(to: root.appendingPathComponent("learning.json"))
  let backups = root.appendingPathComponent("backups")
  try FileManager.default.createSymbolicLink(at: backups, withDestinationURL: outside)
  #expect(throws: CompletionStoreError.self) { try CompletionStore(baseDirectory: root) }
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/migration.json").path))
  #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  try FileManager.default.removeItem(at: backups)
  let retry = try CompletionStore(baseDirectory: root)
  #expect(retry.state.fullLines.isEmpty)
  #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/migration.json").path))
}

@Test("标记写入失败会清理本次备份，但保留已有备份目录", .enabled(if: getuid() != 0))
func completionStoreRemovesOnlyItsFailedBackup() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let fileManager = FileManager.default
  let legacy = root.appendingPathComponent("learning.json")
  try Data("legacy".utf8).write(to: legacy)
  let previous = root.appendingPathComponent("backups/previous")
  try fileManager.createDirectory(at: previous, withIntermediateDirectories: true)
  try Data("keep".utf8).write(to: previous.appendingPathComponent("user-data"))
  let directory = root.appendingPathComponent("v2")
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
  try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
  #expect(throws: CompletionStoreError.self) { try CompletionStore(baseDirectory: root) }
  #expect(try fileManager.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path) == ["previous"])
  #expect(try Data(contentsOf: previous.appendingPathComponent("user-data")) == Data("keep".utf8))
  #expect(try Data(contentsOf: legacy) == Data("legacy".utf8))
  #expect(!fileManager.fileExists(atPath: directory.appendingPathComponent("migration.json").path))
  try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  #expect(try CompletionStore(baseDirectory: root).state == CompletionLearningState())
}

@Test("拒绝旧数据符号链接，包括悬空链接")
func completionStoreRejectsLegacySymlinks() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("local-specs.json"),
    withDestinationURL: root.appendingPathComponent("missing"))
  #expect(throws: CompletionStoreError.self) { try CompletionStore(baseDirectory: root) }
}

@Test("五种清理范围相互独立，重启后保留未选类别", arguments: [
  AutocompleteClearSelection.history, .fullLines, .helpProbe, .learnedFolder, .learnedSpecs,
])
func completionStoreClearsOnlySelectedScope(_ selection: AutocompleteClearSelection) throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try CompletionStore(baseDirectory: root)
  try store.transaction { $0 = completionPopulatedState() }
  try store.clear(selection)
  let reloaded = try CompletionStore(baseDirectory: root)
  #expect(reloaded.state.history.isEmpty == selection.contains(.history))
  #expect(reloaded.state.fullLines.isEmpty == selection.contains(.fullLines))
  #expect(reloaded.state.helpProbe.isEmpty == selection.contains(.helpProbe))
  #expect(reloaded.state.learnedFolder.isEmpty == selection.contains(.learnedFolder))
  #expect(reloaded.state.learnedSpecs.isEmpty == selection.contains(.learnedSpecs))
}

@Test("清理写入失败保留内存及旧文件，不写链接目标")
func completionStoreClearFailureKeepsState() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try CompletionStore(baseDirectory: root)
  let initial = completionPopulatedState()
  try store.transaction { $0 = initial }
  let previous = try Data(contentsOf: store.stateURL)
  let preserved = store.directory.appendingPathComponent("preserved.json")
  try FileManager.default.moveItem(at: store.stateURL, to: preserved)
  try FileManager.default.createSymbolicLink(at: store.stateURL, withDestinationURL: preserved)
  #expect(throws: CompletionStore.ClearFailure.self) { try store.clear(.all) }
  #expect(store.state == initial)
  #expect(try Data(contentsOf: preserved) == previous)
  try FileManager.default.removeItem(at: store.stateURL)
  try FileManager.default.moveItem(at: preserved, to: store.stateURL)
  #expect(try CompletionStore(baseDirectory: root).state == initial)
}

@Test("清理部分失败仍继续其他类别，返回的成功掩码忽略未知位")
func completionStoreClearContinuesAfterFailure() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  var failHelpRemoval = false
  let store = try CompletionStore(baseDirectory: root, writeState: { data, url in
    let next = try JSONDecoder().decode(CompletionLearningState.self, from: data)
    if failHelpRemoval && next.helpProbe.isEmpty { throw CompletionStoreError.writeFailed }
    try data.write(to: url, options: .atomic)
  })
  try store.transaction { $0 = completionPopulatedState() }
  failHelpRemoval = true
  do {
    try store.clear(.all)
    Issue.record("应返回部分清理失败")
  } catch let error as CompletionStore.ClearFailure {
    #expect(error.succeeded == [.history, .fullLines, .learnedFolder, .learnedSpecs])
    #expect(error.failed == .helpProbe)
  }
  let remaining = try CompletionStore(baseDirectory: root).state
  #expect(remaining.history.isEmpty && remaining.fullLines.isEmpty && remaining.learnedFolder.isEmpty)
  #expect(!remaining.helpProbe.isEmpty && remaining.learnedSpecs.isEmpty)
  #expect(try store.clear(AutocompleteClearSelection(rawValue: 1 << 9)).isEmpty)
}

@Test("空清理不写状态文件；开发与正式目录彼此隔离")
func completionStoreEmptyClearAndIdentityIsolation() throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let release = try CompletionStore(baseDirectory: root.appendingPathComponent("Aster/Autocomplete"))
  let dev = try CompletionStore(baseDirectory: root.appendingPathComponent("Aster-Dev/Autocomplete"))
  try dev.clear([])
  #expect(!FileManager.default.fileExists(atPath: dev.stateURL.path))
  try release.transaction { $0 = completionPopulatedState() }
  #expect(dev.state == CompletionLearningState())
  #expect(try CompletionStore(baseDirectory: dev.directory.deletingLastPathComponent()).state == dev.state)
}

func completionTestDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aster-Completion-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}

func completionPopulatedState() -> CompletionLearningState {
  var state = CompletionLearningState()
  let date = Date(timeIntervalSince1970: 100)
  state.history = [.init(command: "git", token: "status", count: 3, lastUsed: date)]
  state.fullLines = [.init(command: "git status", directory: "/project", lastUsed: date)]
  state.helpProbe = [.init(name: "auto", options: [.init(names: ["--help"])])]
  state.learnedFolder = [.init(command: "make deploy", directory: "/project", lastUsed: date)]
  state.learnedSpecs = [.init(name: "custom", options: [.init(names: ["--custom"])])]
  return state
}
