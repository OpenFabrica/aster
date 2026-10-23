// 应用身份：正式版与开发版各用一套数据，两个 App 可以同时运行，互不恢复、互不改写对方的工作区。
import Foundation

/// 当前进程属于正式版还是开发版。
///
/// `scripts/build-app.sh` 打 `-dev` 包时把 bundle ID 改成 `developmentBundleIdentifier`。
/// bundle ID 不同，`UserDefaults.standard`（工作区快照、运行标记、偏好）自然分开；本类型再把
/// Application Support、日志目录、控制 socket 与钥匙串里的单例条目按身份分开。
/// 不在 App 包里运行的 SwiftPM 产物（`swift run`、`.build/debug/aster-cli`、测试宿主）一律按
/// 开发版处理，碰不到正式版的数据。
public enum AsterAppIdentity: String, Sendable, CaseIterable {
  case release
  case development

  /// 正式版 bundle ID。
  public static let releaseBundleIdentifier = "io.local.aster-terminal"
  /// 开发版 bundle ID，只由 `scripts/build-app.sh` 写进 `-dev` 包的 Info.plist。
  public static let developmentBundleIdentifier = "io.local.aster-terminal.dev"

  /// 当前进程的身份，进程内不变。
  public static let current = AsterAppIdentity(
    appBundleIdentifier: Bundle.main.executableURL.flatMap(enclosingAppBundleIdentifier(executableURL:)))

  /// 按所在 App 包的 bundle ID 判定：不在 App 包里（nil）或是开发版 ID 都算开发版，其余算正式版。
  public init(appBundleIdentifier: String?) {
    guard let appBundleIdentifier, appBundleIdentifier != Self.developmentBundleIdentifier else {
      self = .development
      return
    }
    self = .release
  }

  /// 解析符号链接后，可执行文件位于 `X.app/Contents/MacOS/` 时返回 `X.app` 的 bundle ID，否则返回 nil。
  ///
  /// 不直接用 `Bundle.main.bundleIdentifier`：设置页装的 `/usr/local/bin/aster` 是指向包内
  /// `aster-cli` 的符号链接，按链接所在目录找不到 App 包，CLI 会认错身份、连错 socket。
  public static func enclosingAppBundleIdentifier(executableURL: URL) -> String? {
    let macOS = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
      app.pathExtension == "app"
    else { return nil }
    return Bundle(url: app)?.bundleIdentifier
  }

  /// `~/Library/Application Support/` 与 `~/Library/Logs/` 下的目录名。
  public var dataDirectoryName: String {
    switch self {
    case .release: "Aster"
    case .development: "Aster-Dev"
    }
  }

  /// 本身份的 Application Support 目录。只计算路径，不创建目录。
  public func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    return base.appendingPathComponent(dataDirectoryName, isDirectory: true)
  }

  /// 钥匙串 service 后缀。agent 主机授权这类全局只有一条的条目，开发版要另用一条：
  /// 读正式版的条目会弹钥匙串授权框，写入还会盖掉正式版的授权。
  public var keychainServiceSuffix: String {
    switch self {
    case .release: ""
    case .development: ".dev"
    }
  }
}
