// `sticky-notes.json` 的读写：创建时同步读一次（有大小上限），之后去抖写盘，在串行队列上原子写入。
// 打字时每次按键都会改便笺，去抖避免频繁写盘；App 退出前 `flush()` 把最后的改动写出。
import AsterCore
import Foundation

/// 便笺文件的唯一持有者。只在主线程使用；写盘在后台串行队列上按提交顺序进行。
@MainActor
final class StickyNoteStore {
  /// 读取时的大小上限；超过按损坏处理。
  static let maximumFileBytes = 32 * 1_048_576

  let fileURL: URL
  private(set) var file: StickyNoteFile
  private let saveDelay: Duration
  private let writer = DispatchQueue(label: "aster.stickies.writer", qos: .utility)
  private var saveTask: Task<Void, Never>?

  /// 读取 `fileURL`；不存在时从空开始；损坏时把原文件改名为 `.bad` 留底，再从空开始，不覆盖用户数据。
  init(fileURL: URL, saveDelay: Duration = .milliseconds(600)) {
    self.fileURL = fileURL
    self.saveDelay = saveDelay
    switch Self.load(fileURL) {
    case .success(let loaded):
      file = loaded ?? StickyNoteFile()
    case .failure(let error):
      file = StickyNoteFile()
      DiagnosticsCenter.shared.record("stickies.load_failed", level: .warning, category: .storage, error: error)
      let backup = fileURL.appendingPathExtension("bad")
      writer.async {
        do {
          if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
          try FileManager.default.moveItem(at: fileURL, to: backup)
        } catch {
          DiagnosticsCenter.shared.record("stickies.backup_failed", level: .warning, category: .storage, error: error)
        }
      }
    }
  }

  /// 修改便笺并去抖写盘。
  func update(_ change: (inout StickyNoteFile) -> Void) {
    change(&file)
    saveTask?.cancel()
    let delay = saveDelay
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return  // 被新的改动或立即写盘取代
      }
      self?.saveTask = nil
      self?.enqueueWrite()
    }
  }

  /// 把尚未写出的改动立即写出并等写完（App 退出、测试断言前）。会短暂阻塞调用线程。
  func flush() {
    if saveTask != nil {
      saveTask?.cancel()
      saveTask = nil
      enqueueWrite()
    }
    writer.sync {}
  }

  /// 编码当前内容并交给串行队列原子写入；先提交的先写，旧内容不会覆盖新内容。
  private func enqueueWrite() {
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      data = try encoder.encode(file)
    } catch {
      DiagnosticsCenter.shared.record("stickies.encode_failed", level: .error, category: .storage, error: error)
      return
    }
    let url = fileURL
    writer.async {
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        DiagnosticsCenter.shared.record("stickies.write_failed", level: .error, category: .storage, error: error)
      }
    }
  }

  /// 读并解码。不存在返回 `.success(nil)`；太大、读不了或格式不对返回错误。
  private static func load(_ url: URL) -> Result<StickyNoteFile?, any Error> {
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= maximumFileBytes else { return .failure(CocoaError(.fileReadTooLarge)) }
      return .success(try JSONDecoder().decode(StickyNoteFile.self, from: Data(contentsOf: url)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .success(nil)
    } catch {
      return .failure(error)
    }
  }
}
