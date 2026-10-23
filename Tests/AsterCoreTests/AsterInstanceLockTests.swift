import Darwin
import Foundation
import Testing

@testable import AsterCore

/// 单实例锁：同一个锁文件只能有一个持有者，持有者释放后可以再抢。
struct AsterInstanceLockTests {
  /// 每个用例一个独立目录，锁文件放在里面，模拟数据目录还不存在的首次启动。
  private func makeLockURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("AsterInstanceLockTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent(AsterInstanceLock.fileName)
  }

  @Test("锁被占用时第二次抢锁失败并读到持有者 PID；持有者释放后能重新抢到")
  func secondClaimSeesOwnerUntilReleased() throws {
    let url = makeLockURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    do {
      guard case .acquired(let holder) = try AsterInstanceLock.acquire(at: url) else {
        Issue.record("锁文件空闲时应该抢到锁")
        return
      }
      guard case .heldByAnotherProcess(let ownerPID) = try AsterInstanceLock.acquire(at: url) else {
        Issue.record("锁被占用时第二次抢锁必须失败")
        return
      }
      #expect(ownerPID == getpid())
      withExtendedLifetime(holder) {}
    }
    // holder 出了作用域即被释放，flock 随描述符关闭而释放。
    guard case .acquired = try AsterInstanceLock.acquire(at: url) else {
      Issue.record("持有者释放后应该能重新抢到锁")
      return
    }
  }

  @Test("首次抢锁建出 0700 目录与 0600 锁文件，写入本进程 PID，描述符不让子进程继承")
  func lockFileLayout() throws {
    let url = makeLockURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    guard case .acquired(let holder) = try AsterInstanceLock.acquire(at: url) else {
      Issue.record("锁文件空闲时应该抢到锁")
      return
    }
    let fileManager = FileManager.default
    let fileMode = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    let directoryMode = try fileManager.attributesOfItem(
      atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600)
    #expect(directoryMode?.intValue == 0o700)
    #expect(try String(contentsOf: url, encoding: .utf8) == String(getpid()))
    // 子进程（Shell）继承到描述符的话，App 崩溃后锁仍被攥着，下次启动会被误判成已有实例。
    #expect(holder.isCloseOnExec)
  }
}
