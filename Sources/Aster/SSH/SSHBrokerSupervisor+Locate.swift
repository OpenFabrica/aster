import AsterCore
import Foundation

// aster-ssh 的定位、引擎选择与 broker 环境过滤。开发期覆盖（`ASTER_SSH_BINARY`、仓库构建产物、
// 关票开关）只在 DEBUG 构建生效：发行版 App 的环境可被同一用户的任何进程经 `launchctl setenv`
// 改写，若照样认这些变量，就能让 App 把保险库私钥交给伪造的 broker，或关掉启动票据校验。

extension SSHBrokerSupervisor {
  // MARK: - 定位与引擎选择

  /// 可执行文件名。
  nonisolated static let executableName = "aster-ssh"

  /// 当前构建是否接受开发期覆盖；只有 DEBUG 构建为 true。
  nonisolated static var allowsDevelopmentOverrides: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  /// 定位 aster-ssh。DEBUG：`ASTER_SSH_BINARY` → App 包 `Contents/MacOS/aster-ssh` →
  /// 与主程序同目录 → 开发构建 `SshRuntime/target/{release,debug}/aster-ssh`；发行版只认 App 包内的。
  nonisolated static func executableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
  ) -> URL? {
    locate(
      environment: environment, bundleURL: bundle.bundleURL, mainExecutableURL: bundle.executableURL,
      fileManager: .default)
  }

  /// `executableURL` 的可注入版本。
  ///
  /// aster-session 在开发构建里只能靠环境变量指定；aster-ssh 多给两个开发候选：
  /// SwiftPM 调试产物在 `<仓库>/.build/<配置>/Aster`，与之同目录的 aster-ssh 覆盖手工复制的情况；
  /// 由 `.build` 反推出仓库根后再找 cargo 产物，覆盖「只跑了 cargo build」的常见情况。
  /// `allowsDevelopmentOverrides` 为 false 时（发行版）只看 App 包 `Contents/MacOS/aster-ssh`。
  nonisolated static func locate(
    environment: [String: String],
    bundleURL: URL,
    mainExecutableURL: URL?,
    fileManager: FileManager,
    allowsDevelopmentOverrides: Bool = SSHBrokerSupervisor.allowsDevelopmentOverrides
  ) -> URL? {
    let bundled = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
    guard allowsDevelopmentOverrides else {
      return fileManager.isExecutableFile(atPath: bundled.path) ? bundled.standardizedFileURL : nil
    }
    var candidates: [URL] = []
    if let override = environment["ASTER_SSH_BINARY"], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: override))
    }
    candidates.append(bundled)
    if let mainExecutableURL {
      let directory = mainExecutableURL.deletingLastPathComponent()
      candidates.append(directory.appendingPathComponent(executableName))
      let components = directory.standardizedFileURL.pathComponents
      if let buildIndex = components.lastIndex(of: ".build"), buildIndex > 0 {
        let root = NSString.path(withComponents: Array(components[..<buildIndex]))
        for configuration in ["release", "debug"] {
          candidates.append(
            URL(fileURLWithPath: root)
              .appendingPathComponent("SshRuntime/target/\(configuration)/\(executableName)"))
        }
      }
    }
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }?.standardizedFileURL
  }

  /// 拉起 broker 用的环境：发行版去掉关票调试开关 `ASTER_SSH_TICKETS`。
  ///
  /// 发行版 broker 自己也忽略它（只在 `debug_assertions` 下生效），这里再删一次，
  /// 防止 DEBUG 构建的 broker 被误装进发行版 App 时开关重新生效。
  nonisolated static func brokerEnvironment(
    from environment: [String: String],
    allowsDevelopmentOverrides: Bool = SSHBrokerSupervisor.allowsDevelopmentOverrides
  ) -> [String: String] {
    guard !allowsDevelopmentOverrides else { return environment }
    var filtered = environment
    filtered.removeValue(forKey: ticketsSwitchEnvironmentKey)
    return filtered
  }

  /// broker 的关票调试开关（与 `SshRuntime/src/tickets.rs` 的 `SWITCH_ENV` 一致）。
  nonisolated static let ticketsSwitchEnvironmentKey = "ASTER_SSH_TICKETS"

  /// 用户要求的引擎：环境变量 `ASTER_SSH_ENGINE` 优先，其次设置项。
  /// 环境变量取值非法时忽略它并返回说明，由调用方记诊断。
  nonisolated static func requestedEngine(
    environment: [String: String], preferred: SSHEngine
  ) -> (engine: SSHEngine, problem: String?) {
    guard let raw = environment[SSHEngine.environmentKey]?.trimmingCharacters(in: .whitespaces),
      !raw.isEmpty
    else { return (preferred, nil) }
    guard let engine = SSHEngine(rawValue: raw.lowercased()) else {
      return (preferred, "invalid \(SSHEngine.environmentKey)=\(raw)")
    }
    return (engine, nil)
  }
}
