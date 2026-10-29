import Foundation
import os

// 后台会话服务的构建号：识别 App 升级后仍在运行的旧服务。

/// `aster-session` 的构建号是运行时源码的摘要（`scripts/build-session-runtime.sh` 写入）。
///
/// 本机服务活过 App 退出与升级，正在运行的进程仍是旧二进制，新修复不会生效。App 连上
/// 服务时比较「服务报的构建号」和「App 自带二进制的构建号」，不一样就是旧服务。
public enum ManagedSessionServerBuild {
  /// 按路径缓存自带二进制的构建号；文件大小或修改时间变了就重新读，避免每次连接都起进程。
  private struct CachedBuild: Sendable {
    var size: Int
    var modified: Date
    var build: String?
  }
  private static let cache = OSAllocatedUnfairLock(initialState: [String: CachedBuild]())

  /// 从 `aster-session 0.1.0-dev protocol=1.0 build=<id>` 取出 `<id>`；没有该字段时为 nil。
  public static func parse(versionLine: String) -> String? {
    let line = versionLine.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let fields = line.split(separator: " ")
    guard fields.first == "aster-session" else { return nil }
    for field in fields.dropFirst() where field.hasPrefix("build=") {
      let value = field.dropFirst("build=".count)
      return value.isEmpty ? nil : String(value)
    }
    return nil
  }

  /// 服务是否比 App 自带的二进制旧。
  ///
  /// App 侧构建号未知（不在 git 工作区里的构建、读取失败）时不判过期，避免误停正常服务；
  /// 服务没有构建号而 App 有，说明服务来自加入构建号之前的版本，判为过期。
  public static func isOutdated(server: String?, bundled: String?) -> Bool {
    guard let bundled, !bundled.isEmpty else { return false }
    return server != bundled
  }

  /// 运行 `<binaryPath> --version` 读出构建号；结果按文件大小与修改时间缓存。
  /// 读取失败返回 nil，调用方据此不做比较。
  public static func bundled(binaryPath: String, client: LocalManagedSessionClient) -> String? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: binaryPath)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
    let modified = attributes?[.modificationDate] as? Date ?? .distantPast
    if let hit = cache.withLock({ $0[binaryPath] }), hit.size == size, hit.modified == modified {
      return hit.build
    }
    guard let output = try? client.executeStructured(binaryPath: binaryPath, arguments: ["--version"])
    else { return nil }
    let build = parse(versionLine: output)
    cache.withLock {
      $0[binaryPath] = CachedBuild(size: size, modified: modified, build: build)
    }
    return build
  }
}

/// 连上受管服务后的结果：服务身份，加上「旧服务仍有终端在运行」时需要用户决定的终端数。
public struct ManagedServerAttachment: Equatable, Sendable {
  public var identity: SessionServerIdentity
  /// 服务比 App 自带的二进制旧、又有终端在运行时，为运行中的终端数；否则为 0。
  /// 大于 0 时不能静默替换：替换会结束这些终端，由调用方先问用户。
  public var outdatedRunningTerminals: Int
  /// 有终端在运行却没能实时交接时的原因（旧服务不支持、交接失败）；交接成功或无需交接时为 nil。
  public var liveHandoffFailure: String?

  public init(
    identity: SessionServerIdentity, outdatedRunningTerminals: Int = 0, liveHandoffFailure: String? = nil
  ) {
    self.identity = identity
    self.outdatedRunningTerminals = outdatedRunningTerminals
    self.liveHandoffFailure = liveHandoffFailure
  }
}
