// 单实例启动：同一身份（正式版 / 开发版）同时只跑一个 Aster 进程。
import AppKit
import AsterCore

/// 启动最早一步抢 `AsterInstanceLock`。
///
/// 抢不到说明同一身份的 Aster 还活着。第二个进程如果照常启动，会把对方的「正在运行」标记
/// 当成崩溃，恢复同一份快照，再 resume 同一批 agent 会话，之后两边还会抢着写快照。
/// 所以它只把对方调到前台，然后退出。正式版与开发版身份不同、锁也不同，可以同时运行。
@MainActor
enum AsterSingleInstance {
  /// 本进程持有的锁，直到进程退出由内核释放。
  private static var lock: AsterInstanceLock?
  /// 抢锁时的系统错误。诊断会话还没开始，先存着，由 `recordPendingFailure` 补记。
  private static var pendingFailure: (any Error)?

  /// 返回 false 表示同一身份的另一个实例正在运行，调用方应立即退出。
  static func claim(identity: AsterAppIdentity = .current) -> Bool {
    let lockURL = identity.applicationSupportDirectory()
      .appendingPathComponent(AsterInstanceLock.fileName)
    do {
      switch try AsterInstanceLock.acquire(at: lockURL) {
      case .acquired(let acquired):
        lock = acquired
        return true
      case .heldByAnotherProcess(let ownerPID):
        let owner = ownerPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        _ = owner?.activate(options: [])
        // `swift run` 没有窗口可切，终端里要能看到为什么直接退出了。
        let pidText = ownerPID.map { " (pid \($0))" } ?? ""
        FileHandle.standardError.write(
          Data("Aster (\(identity.rawValue)) is already running\(pidText); exiting.\n".utf8))
        return false
      }
    } catch {
      // 锁文件打不开（权限、磁盘满）时不能挡住用户进终端：照常启动，只是失去单实例保护。
      pendingFailure = error
      return true
    }
  }

  /// 诊断会话开始后补记抢锁失败；没有失败时什么都不做。
  static func recordPendingFailure() {
    guard let failure = pendingFailure else { return }
    pendingFailure = nil
    DiagnosticsCenter.shared.record(
      "application.instance_lock_unavailable", level: .warning, category: .lifecycle, error: failure)
  }
}
