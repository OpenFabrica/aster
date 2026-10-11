// 有界子进程输出的单一读取者，串行协调异步回调与退出收尾。
import Darwin
import Foundation

/// 独占管道读端；调用方不得再从该 FileHandle 读取或关闭它。
/// 所有状态及 POSIX read 均受 lock 保护；FileHandle 仅用于可读通知，避免
/// availableData 把 EAGAIN/关闭竞争变成无法用 Swift catch 捕获的 Objective-C 异常。
final class PipeOutputCapture: @unchecked Sendable {
  struct Result: Sendable {
    let data: Data
    let exceededLimit: Bool
    let readError: Int32?
  }

  private let handle: FileHandle
  private let descriptor: Int32
  private let maximumBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var exceededLimit = false
  private var readError: Int32?
  private var finished = false
  private var reachedEOF = false

  /// 安装可读通知并把读端设为非阻塞；配置失败抛出 POSIXError。
  /// stopProcess 在输出超限或读取失败后调用，不能在其中再次读取管道。
  init(handle: FileHandle, maximumBytes: Int, stopProcess: @escaping @Sendable () -> Void) throws {
    guard maximumBytes > 0 else { throw POSIXError(.EINVAL) }
    self.handle = handle
    self.descriptor = handle.fileDescriptor
    self.maximumBytes = maximumBytes
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    handle.readabilityHandler = { [weak self] _ in
      guard let self else { return }
      let state = self.lock.withLock {
        guard !self.finished else { return (false, false) }
        self.drainLocked()
        let failed = self.exceededLimit || self.readError != nil
        return (self.reachedEOF || failed, failed)
      }
      if state.0 { self.handle.readabilityHandler = nil }
      if state.1 { stopProcess() }
    }
  }

  /// 取消通知并等待正在读取的回调释放锁，再取走已到达的尾部数据。
  /// 不等待 EOF（孙进程可能保留写端）；重复调用返回同一结果，迟到回调不再读。
  func finish() -> Result {
    handle.readabilityHandler = nil
    return lock.withLock {
      if !finished {
        drainLocked()
        finished = true
      }
      return Result(data: data, exceededLimit: exceededLimit, readError: readError)
    }
  }

  deinit {
    handle.readabilityHandler = nil
  }

  /// 仅在持锁时调用；最多读取上限加一个字节，以区分恰好到达上限与真正超限。
  private func drainLocked() {
    guard !reachedEOF, !exceededLimit, readError == nil else { return }
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let remaining = maximumBytes - data.count
      let capacity = remaining >= buffer.count ? buffer.count : remaining + 1
      let count = Darwin.read(descriptor, &buffer, capacity)
      if count > 0 {
        data.append(contentsOf: buffer.prefix(min(count, remaining)))
        if count > remaining {
          exceededLimit = true
          return
        }
      } else if count == 0 {
        reachedEOF = true
        return
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      } else {
        readError = errno
        return
      }
    }
  }
}
