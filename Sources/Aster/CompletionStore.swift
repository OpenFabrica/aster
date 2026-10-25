// 补全学习的原子存储与旧格式备份；不访问通用 CLI 传输文件。
import AsterCore
import Darwin
import Foundation

enum CompletionStoreError: Error, LocalizedError {
  case unsafePath
  case invalidState
  case oversizedState
  case backupVerificationFailed
  case backupCleanupFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .unsafePath: L("补全数据路径不是安全的普通文件或目录。")
    case .invalidState: L("补全学习数据格式无效。")
    case .oversizedState: L("补全学习数据超过大小限制。")
    case .backupVerificationFailed: L("旧补全数据备份验证失败，请重试。")
    case .backupCleanupFailed: L("旧补全数据备份失败，临时备份目录未能清理。")
    case .writeFailed: L("无法保存补全学习数据。")
    }
  }
}

/// 每次事务原子提交；写入失败时磁盘旧文件与内存状态保持不变。
/// 由主线程服务持有，初始化或事务错误必须由调用方明确处理。
final class CompletionStore {
  struct ClearFailure: Error, LocalizedError {
    let succeeded: AutocompleteClearSelection
    let failed: AutocompleteClearSelection

    var errorDescription: String? { L("部分补全数据未能清除，请重试。") }
  }

  static let maximumBytes = 32 * 1_024 * 1_024
  static let legacyNames = [
    "learning.json", "local-specs.json", "fig-specs.json", "transitions.json", "path-habits.json",
  ]

  let directory: URL
  let stateURL: URL
  private let fileManager: FileManager
  private let writeState: (Data, URL) throws -> Void
  private(set) var state: CompletionLearningState

  init(
    baseDirectory: URL,
    fileManager: FileManager = .default,
    writeState: ((Data, URL) throws -> Void)? = nil
  ) throws {
    self.fileManager = fileManager
    self.writeState = writeState ?? { data, url in try Self.write(data, to: url, fileManager: fileManager) }
    let base = baseDirectory.standardizedFileURL
    directory = base.appendingPathComponent("v2", isDirectory: true)
    stateURL = directory.appendingPathComponent("learning.json")
    try Self.prepareDirectory(base, fileManager: fileManager)
    try Self.prepareDirectory(directory, fileManager: fileManager)
    try Self.backupLegacyIfNeeded(base: base, directory: directory, fileManager: fileManager)
    if let data = try Self.readOptional(stateURL) {
      let decoded = try JSONDecoder().decode(CompletionLearningState.self, from: data)
      guard decoded.schemaVersion == 2,
        decoded.history.allSatisfy({ $0.count > 0 && $0.score.isFinite && $0.lastUsed.timeIntervalSince1970.isFinite }),
        (decoded.fullLines + decoded.learnedFolder).allSatisfy({
          $0.count > 0 && $0.score.isFinite && $0.lastUsed.timeIntervalSince1970.isFinite
        })
      else { throw CompletionStoreError.invalidState }
      state = decoded
    } else {
      state = CompletionLearningState()
    }
  }

  /// 变更只作用于副本；编码、校验及原子替换都成功后才更新读取者看到的状态。
  func transaction(_ change: (inout CompletionLearningState) throws -> Void) throws {
    var next = state
    try change(&next)
    guard next != state else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(next)
    guard data.count <= Self.maximumBytes else { throw CompletionStoreError.oversizedState }
    try Self.prepareDirectory(directory, fileManager: fileManager)
    try writeState(data, stateURL)
    state = next
  }

  /// 原版原生入口逐范围清理，失败后继续处理其余范围，只汇总成功位。
  /// 未知位被忽略；按原版固定的 1、2、4、8、16 顺序执行。
  @discardableResult
  func clear(_ selection: AutocompleteClearSelection) throws -> AutocompleteClearSelection {
    var succeeded: AutocompleteClearSelection = []
    var failed: AutocompleteClearSelection = []
    for scope: AutocompleteClearSelection in [.history, .fullLines, .helpProbe, .learnedFolder, .learnedSpecs]
    where selection.contains(scope) {
      do {
        try transaction { $0.clear(scope) }
        succeeded.insert(scope)
      } catch {
        failed.insert(scope)
      }
    }
    if !failed.isEmpty { throw ClearFailure(succeeded: succeeded, failed: failed) }
    return succeeded
  }

  private struct Migration: Codable {
    let version: Int
    let backup: String?
    let files: [String]
  }

  private static func backupLegacyIfNeeded(base: URL, directory: URL, fileManager: FileManager) throws {
    let marker = directory.appendingPathComponent("migration.json")
    if let data = try readOptional(marker) {
      let migrated = try JSONDecoder().decode(Migration.self, from: data)
      guard migrated.version == 2 else { throw CompletionStoreError.invalidState }
      return
    }
    var originals: [(String, Data)] = []
    for name in legacyNames {
      if let data = try readOptional(base.appendingPathComponent(name)) { originals.append((name, data)) }
    }
    var ownedBackup: URL?
    do {
      var backupName: String?
      if !originals.isEmpty {
        let backups = base.appendingPathComponent("backups", isDirectory: true)
        try prepareDirectory(backups, fileManager: fileManager)
        let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)-legacy-v1"
        let target = backups.appendingPathComponent(name, isDirectory: true)
        // mkdir 必须新建成功才取得清理所有权，绝不复用或删除已有目录。
        guard mkdir(target.path, 0o700) == 0 else { throw CompletionStoreError.unsafePath }
        ownedBackup = target
        for (name, data) in originals {
          let copied = target.appendingPathComponent(name)
          try write(data, to: copied, fileManager: fileManager)
          guard try readOptional(copied) == data else { throw CompletionStoreError.backupVerificationFailed }
        }
        backupName = "backups/\(name)"
      }
      // 备份完成后才写标记；原文件完全保留，新版本不导入其中的任何学习内容。
      let record = Migration(version: 2, backup: backupName, files: originals.map(\.0))
      try write(try JSONEncoder().encode(record), to: marker, fileManager: fileManager)
    } catch let failure {
      if let ownedBackup {
        do { try fileManager.removeItem(at: ownedBackup) }
        catch { throw CompletionStoreError.backupCleanupFailed }
      }
      throw failure
    }
  }

  private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
    var info = stat()
    if lstat(url.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFDIR else { throw CompletionStoreError.unsafePath }
      return
    }
    guard errno == ENOENT else { throw CompletionStoreError.unsafePath }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw CompletionStoreError.unsafePath
    }
  }

  /// 使用 O_NOFOLLOW 区分不存在和不安全文件，包括指向不存在目标的符号链接。
  private static func readOptional(_ url: URL) throws -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw CompletionStoreError.unsafePath
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0, metadata.st_size <= maximumBytes
    else { throw CompletionStoreError.unsafePath }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while data.count <= maximumBytes {
      let count = read(descriptor, &buffer, min(buffer.count, maximumBytes - data.count + 1))
      guard count >= 0 else { throw CompletionStoreError.unsafePath }
      if count == 0 { return data }
      data.append(contentsOf: buffer.prefix(count))
    }
    throw CompletionStoreError.oversizedState
  }

  private static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
    var info = stat()
    if lstat(url.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFREG else { throw CompletionStoreError.unsafePath }
    } else if errno != ENOENT { throw CompletionStoreError.unsafePath }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".completion-\(UUID().uuidString)")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw CompletionStoreError.writeFailed }
    defer {
      close(descriptor)
      // rename 已成功时临时路径不存在；失败只回收本次创建的临时文件。
      unlink(temporary.path)
    }
    try data.withUnsafeBytes { bytes in
      guard let start = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(descriptor, start.advanced(by: written), bytes.count - written)
        guard count > 0 else { throw CompletionStoreError.writeFailed }
        written += count
      }
    }
    guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
      throw CompletionStoreError.writeFailed
    }
  }
}
