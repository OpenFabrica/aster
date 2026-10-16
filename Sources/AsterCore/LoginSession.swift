import Darwin

// macOS 登录（审计）会话：识别活过注销、已连不上当前桌面的后台服务。

/// 当前进程所在的 macOS 审计会话。每次登录图形界面都会分到新的会话 ID。
public enum LoginSession {
  /// 当前进程的审计会话 ID；系统调用失败时为 nil。
  public static var current: UInt32? {
    var info = auditinfo_addr()
    guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0,
      info.ai_asid > 0
    else { return nil }
    return UInt32(info.ai_asid)
  }

  /// 服务是否属于另一个登录会话。任一侧未知（旧版服务、调用失败）时不判过期，
  /// 避免误停一个其实正常的服务。
  public static func isStale(server: UInt32?, current: UInt32?) -> Bool {
    guard let server, let current else { return false }
    return server != current
  }
}
