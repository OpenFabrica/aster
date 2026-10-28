import Darwin
import Foundation
import AsterCore

enum FileSystemDirectoryWatcherError: Error, LocalizedError, Equatable {
  case cannotOpenDirectory(Int32)
  case cannotOpenFile(Int32)

  var errorDescription: String? {
    switch self {
    case .cannotOpenDirectory(let code):
      L("无法监听本地目录（errno=\(String(code))）。")
    case .cannotOpenFile(let code):
      L("无法监听本地文件（errno=\(String(code))）。")
    }
  }
}

/// 以 vnode 事件观察一个已经存在的本地目录，不读取目录或文件内容。
///
/// 文件系统允许合并相邻事件，因此 `onChange` 只表示“目录可能变化”；调用方必须重新读取
/// 自己关心的有界状态，不能假设一个事件对应一个文件。监听源固定运行在主队列，适合
/// 唤醒 AppKit 状态协调器；耗时读取仍应由调用方转移到现有后台基础设施边界。
@MainActor
final class FileSystemDirectoryWatcher {
  private let directory: URL
  private let eventMask: DispatchSource.FileSystemEvent
  private let isFile: Bool
  // DispatchSource 的取消和 deinit 都允许从非隔离上下文发生；生产读写仍只在 MainActor。
  private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?

  init(directory: URL) {
    self.directory = directory.standardizedFileURL
    eventMask = [.write, .delete, .rename, .attrib, .revoke]
    isFile = false
  }

  /// 监听普通文件的追加或替换（vnode 对文件同样可用）。追加写同时触发 `.write` 与
  /// `.extend`；文件被改名或删除时上报，调用方应停止并重新定位。
  init(file: URL) {
    directory = file.standardizedFileURL
    eventMask = [.write, .extend, .delete, .rename, .revoke]
    isFile = true
  }

  var isWatching: Bool { source != nil }

  /// 开始监听目录条目与属性变化。重复调用保持现有监听，不会创建第二个文件描述符。
  func start(onChange: @escaping @MainActor @Sendable () -> Void) throws {
    guard source == nil else { return }
    let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw isFile
        ? FileSystemDirectoryWatcherError.cannotOpenFile(errno)
        : FileSystemDirectoryWatcherError.cannotOpenDirectory(errno)
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: eventMask,
      queue: .main
    )
    source.setEventHandler {
      MainActor.assumeIsolated { onChange() }
    }
    source.setCancelHandler {
      Darwin.close(descriptor)
    }
    self.source = source
    source.activate()
  }

  /// 监听目录，但只在其中的 `file` 真的变了（换了文件、大小或修改时间不同、出现或消失）才回调。
  ///
  /// 目录事件不带文件名：同目录里任何文件写盘都会唤醒监听。配置目录（Application Support）
  /// 同时放着便笺、工具状态等频繁写入的文件，不过滤就会每次都整份重读配置并通知界面。
  /// 基准取开始监听时的状态；之后自己写盘同样会改变文件，照常回调。
  func start(onChangeOf file: URL, onChange: @escaping @MainActor @Sendable () -> Void) throws {
    let tracker = FileChangeTracker(file: file)
    try start {
      guard tracker.consumeChange() else { return }
      onChange()
    }
  }

  /// 停止监听并异步关闭文件描述符。重复调用没有额外副作用。
  func stop() {
    let source = source
    self.source = nil
    source?.cancel()
  }

  deinit {
    source?.cancel()
  }
}

/// 一个文件此刻的身份与内容标记：设备、inode、大小与修改时间（纳秒）。文件不存在时为 nil。
/// 原子写会换 inode，原地写会改大小或修改时间，都能区分出来。
struct FileChangeStamp: Equatable {
  let device: Int64
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int

  /// 读取 `url` 的标记；读不到（不存在、无权限）返回 nil。
  static func of(_ url: URL) -> FileChangeStamp? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return FileChangeStamp(
      device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
      modifiedSeconds: Int(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec))
  }
}

/// 记住文件上一次的标记，判断这次目录事件是不是它变了。只在主线程使用。
@MainActor
final class FileChangeTracker {
  private let file: URL
  private var last: FileChangeStamp?

  /// 以当前状态为基准。
  init(file: URL) {
    self.file = file
    last = FileChangeStamp.of(file)
  }

  /// 文件和上次相比变了就返回 true，并把基准更新为当前状态。
  func consumeChange() -> Bool {
    let current = FileChangeStamp.of(file)
    guard current != last else { return false }
    last = current
    return true
  }
}
