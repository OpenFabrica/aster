// 读取某个进程所在终端的前台进程组，供本机受管终端的 Agent 识别使用。

import Darwin

/// 通过 `sysctl(KERN_PROC_PID)` 取 `kinfo_proc.e_tpgid`（控制终端的前台进程组）。
///
/// 为什么需要：受管终端的 Shell 跑在后台服务里，App 内 Ghostty surface 的前台进程是显示桥
/// `aster-session terminal attach`，不是用户的命令；只有拿服务端上报的 Shell pid 去问内核，
/// 才知道它的终端前台现在是谁（例如重启 App 后仍在运行的 Codex）。
enum ProcessForegroundGroupReader {
  /// 返回 `pid` 的控制终端当前前台进程组 id；进程不存在、没有控制终端或无权限时返回 nil。
  static func foregroundGroup(of pid: Int32) -> Int32? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let group = info.kp_eproc.e_tpgid
    return group > 0 ? group : nil
  }
}
