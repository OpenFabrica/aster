// `tools-state.json` 的读写：创建时同步读一次（文件很小，有大小上限），之后改动在串行队列上原子写；
// 使用记录变化频繁，去抖后再写。授权只存在这里，不进 settings.json。
import AsterCore
import Foundation

/// 工具中心状态文件的唯一持有者。只在主线程使用；写盘在后台串行队列上按提交顺序进行。
@MainActor
final class ToolStateStore {
  /// 读取时的大小上限；超过按损坏处理，不读进内存。
  static let maximumFileBytes = 4 * 1_048_576

  let fileURL: URL
  private(set) var state: ToolStateFile
  /// 文件存在但读不了时的说明，工具中心把它当作一条问题展示。
  private(set) var loadIssue: ToolPluginIssue?
  private let usageSaveDelay: Duration
  private let writer = DispatchQueue(label: "aster.tools.state-writer", qos: .utility)
  private var usageSaveTask: Task<Void, Never>?

  /// 读取 `fileURL`；不存在时从空状态开始，损坏时把原文件改名为 `.bad` 留底再从空状态开始。
  init(fileURL: URL, usageSaveDelay: Duration = .seconds(2)) {
    self.fileURL = fileURL
    self.usageSaveDelay = usageSaveDelay
    switch Self.load(fileURL) {
    case .success(let loaded):
      state = loaded ?? ToolStateFile()
    case .failure(let failure):
      state = ToolStateFile()
      loadIssue = ToolPluginIssue(path: fileURL.path, message: failure.message)
      let backup = fileURL.appendingPathExtension("bad")
      writer.async {
        do {
          if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
          try FileManager.default.moveItem(at: fileURL, to: backup)
        } catch {
          DiagnosticsCenter.shared.record(
            "tools.state_backup_failed", level: .warning, category: .storage, error: error)
        }
      }
    }
  }

  /// 修改状态并立即排队写盘（启用、授权、开发目录这类用户决定不能丢）。
  func update(_ change: (inout ToolStateFile) -> Void) {
    change(&state)
    usageSaveTask?.cancel()
    usageSaveTask = nil
    enqueueWrite()
  }

  /// 记一次使用；去抖后写盘。
  func recordUse(_ entryID: String, at date: Date) {
    state.usage.recordUse(entryID, at: date)
    usageSaveTask?.cancel()
    let delay = usageSaveDelay
    usageSaveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return  // 被新的记录或立即写盘取代
      }
      self?.usageSaveTask = nil
      self?.enqueueWrite()
    }
  }

  /// 把尚未写出的改动立即写出并等写完（App 退出、测试断言前）。会短暂阻塞调用线程。
  func flush() {
    if usageSaveTask != nil {
      usageSaveTask?.cancel()
      usageSaveTask = nil
      enqueueWrite()
    }
    writer.sync {}
  }

  /// 编码当前状态并交给串行队列原子写入；队列保证先提交的先写，旧状态不会覆盖新状态。
  private func enqueueWrite() {
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      data = try encoder.encode(state)
    } catch {
      DiagnosticsCenter.shared.record("tools.state_encode_failed", level: .error, category: .storage, error: error)
      return
    }
    let url = fileURL
    writer.async {
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        DiagnosticsCenter.shared.record("tools.state_write_failed", level: .error, category: .storage, error: error)
      }
    }
  }

  /// 读并解码状态文件。不存在返回 `.success(nil)`；太大、读不了或格式不对返回给用户看的说明。
  private static func load(_ url: URL) -> Result<ToolStateFile?, ToolStateLoadFailure> {
    let size: Int
    do {
      size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .success(nil)
    } catch {
      return .failure(ToolStateLoadFailure(message: L("无法读取工具状态：\(error.localizedDescription)")))
    }
    guard size <= maximumFileBytes else {
      return .failure(ToolStateLoadFailure(message: L("工具状态文件太大，已按空状态处理")))
    }
    do {
      return .success(try JSONDecoder().decode(ToolStateFile.self, from: Data(contentsOf: url)))
    } catch {
      return .failure(ToolStateLoadFailure(message: L("工具状态文件已损坏，已按空状态处理")))
    }
  }
}

/// 状态文件读取失败的说明。
struct ToolStateLoadFailure: Error {
  let message: String
}
