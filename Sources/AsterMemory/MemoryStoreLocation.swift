import AsterCore
import Foundation

/// Session Memory 的磁盘位置与权限。独立于 DiagnosticsCenter 的日志目录：
/// 两个通道的脱敏策略不同，绝不共享文件或互相引用。
public struct MemoryStoreLocation: Sendable {
  public let rootDirectory: URL

  /// 数据库文件路径（WAL 模式会伴生 -wal/-shm 文件，同目录同权限）。
  public var databaseURL: URL {
    rootDirectory.appendingPathComponent("memory.sqlite", isDirectory: false)
  }

  /// 生产位置：`~/Library/Application Support/Aster/Memory/`（开发版在 `Aster-Dev` 下）。
  /// 两个身份各用一个库：启动补收会闭合库里「不属于本进程」的 active 会话，共用一个库时
  /// 开发版会把正式版正在跑的会话当成崩溃遗留关掉。
  public static func standard(
    fileManager: FileManager = .default, identity: AsterAppIdentity = .current
  ) -> MemoryStoreLocation {
    MemoryStoreLocation(
      rootDirectory: identity.applicationSupportDirectory(fileManager: fileManager)
        .appendingPathComponent("Memory", isDirectory: true)
    )
  }

  public init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory
  }

  /// 创建目录并收紧权限（目录 0700）。记录内容可能包含命令与输出摘录，
  /// 与 Autocomplete/Diagnostics 目录采用同一防线：仅当前用户可读。
  public func prepareDirectory(fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? fileManager.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
  }
}
