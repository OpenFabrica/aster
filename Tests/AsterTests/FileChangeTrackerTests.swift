// 配置目录监听的文件过滤：同目录别的文件写盘不算，本文件原地改写、原子替换、删除与新建才算。
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite("FileChangeTracker")
struct FileChangeTrackerTests {
  /// 每个测试一个临时目录。
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-file-change-\(UUID().uuidString)", isDirectory: true)

  @Test func onlyChangesToTheTrackedFileCount() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("machines.json")
    let sibling = directory.appendingPathComponent("sticky-notes.json")
    try Data("[]".utf8).write(to: config)
    let tracker = FileChangeTracker(file: config)

    try Data("{\"notes\":[]}".utf8).write(to: sibling, options: .atomic)
    #expect(!tracker.consumeChange())

    // 原子替换：内容大小相同也会换 inode。
    try Data("{}".utf8).write(to: config, options: .atomic)
    #expect(tracker.consumeChange())
    #expect(!tracker.consumeChange())

    try FileManager.default.removeItem(at: config)
    #expect(tracker.consumeChange())
    #expect(!tracker.consumeChange())
    try Data("[]".utf8).write(to: config)
    #expect(tracker.consumeChange())
  }

  /// 目录监听接上过滤：写同目录别的文件不回调，写配置文件才回调。
  @Test func directoryWatcherFiltersUnrelatedFiles() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("hosts.json")
    try Data("[]".utf8).write(to: config)
    let watcher = FileSystemDirectoryWatcher(directory: directory)
    let counter = Counter()
    try watcher.start(onChangeOf: config) { counter.value += 1 }
    defer { watcher.stop() }

    try Data("x".utf8).write(to: directory.appendingPathComponent("tools-state.json"), options: .atomic)
    try await Task.sleep(for: .milliseconds(200))
    #expect(counter.value == 0)

    try Data("[1]".utf8).write(to: config, options: .atomic)
    try await Task.sleep(for: .milliseconds(200))
    #expect(counter.value == 1)
  }
}

/// 回调计数。
@MainActor
private final class Counter {
  var value = 0
}
