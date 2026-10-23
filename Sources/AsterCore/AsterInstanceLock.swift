// 单实例锁：同一身份同时只让一个 Aster 进程使用数据目录。
import Darwin
import Foundation

/// 数据目录里 `instance.lock` 上的 `flock` 独占锁。
///
/// 进程退出或崩溃时内核自动释放，不会留下脏锁，所以它能回答「另一个实例是不是还活着」。
/// UserDefaults 里的「正在运行」标记只能回答「上次有没有正常退出」：两个实例同时开时，后开的
/// 那个会把活着的对方当成崩溃，恢复同一份快照，再 resume 同一批 agent 会话。
/// 锁文件用 `O_CLOEXEC` 打开：Shell 等子进程不能继承这个描述符，否则 App 崩溃后子进程仍攥着锁，
/// 下次启动会被误判成「已有实例在运行」。
public final class AsterInstanceLock: Sendable {
  /// 抢锁结果。
  public enum Outcome: Sendable {
    /// 本进程拿到了锁；调用方要一直持有它，直到进程退出。
    case acquired(AsterInstanceLock)
    /// 锁在别的进程手里。`ownerPID` 读自锁文件；对方还没写入或内容损坏时为 nil。
    case heldByAnotherProcess(ownerPID: pid_t?)
  }

  /// 锁文件名，放在身份对应的 Application Support 目录里。
  public static let fileName = "instance.lock"

  private let fileDescriptor: Int32

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  deinit {
    // 关闭描述符即释放 flock。App 持有到进程退出，这里主要服务测试。
    close(fileDescriptor)
  }

  /// 描述符是否带 `FD_CLOEXEC`；测试用来确认子进程继承不到锁。
  var isCloseOnExec: Bool { fcntl(fileDescriptor, F_GETFD) & FD_CLOEXEC != 0 }

  /// 在 `fileURL` 上抢锁，不等待。父目录不存在时按 0700 创建；打开或加锁的系统错误照常抛出。
  public static func acquire(at fileURL: URL, fileManager: FileManager = .default) throws -> Outcome {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixError(errno) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      defer { close(descriptor) }
      guard code == EWOULDBLOCK else { throw posixError(code) }
      return .heldByAnotherProcess(ownerPID: readOwnerPID(descriptor))
    }
    // 写入本进程 PID，第二个实例据此把我们调到前台。写失败只影响前台切换，不影响锁本身。
    let pid = Array(String(getpid()).utf8)
    _ = ftruncate(descriptor, 0)
    _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    return .acquired(AsterInstanceLock(fileDescriptor: descriptor))
  }

  /// 读锁文件里的 PID，只接受正整数。
  private static func readOwnerPID(_ descriptor: Int32) -> pid_t? {
    var buffer = [UInt8](repeating: 0, count: 16)
    let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count > 0,
      let text = String(bytes: buffer.prefix(count), encoding: .utf8),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
    else { return nil }
    return pid
  }

  /// errno 转成 Foundation 的 POSIXError；未知码按 EIO 处理。
  private static func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }
}
