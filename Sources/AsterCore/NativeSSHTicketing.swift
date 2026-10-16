import CryptoKit
import Foundation
import os

// broker 启动票据的 Swift 侧（SshRuntime/PROTOCOL.md §3 OPEN.ticket、§4.2 tickets.key）。
// 每个 broker 实例一把 32 字节 HMAC 密钥，只经 broker 的私有 stdin 下发；每拉起一个
// `aster-ssh client` 现签一张一次性票据，经环境变量交给它，绝不进 argv 或文件。
// 威胁模型：只挡「配合的」同用户进程绕过 App 直连 broker socket，挡不住恶意软件，
// 见 docs/developer/native-ssh.md「client 认证与威胁模型」。

/// 启动票据签发器。线程安全：Pane 挂载在主线程签票，后台执行器在任意线程签票。
///
/// 票据格式 `v1.<nonce>.<expiryMs>.<hmac>`：nonce 为 16 字节随机数的小写 hex，
/// `hmac = HMAC-SHA256(key, "v1|<nonce>|<expiryMs>")` 的小写 hex。
public final class NativeSSHTicketIssuer: Sendable {
  /// 票据有效期。client 拿到票后立即连接，120 秒足够覆盖慢启动。
  public static let lifetime: Duration = .seconds(120)

  /// 当前密钥；nil 表示 broker 不在或已关闭，此时不签票。
  private let key = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)

  public init() {}

  /// 换一把新密钥，返回小写 hex 供 `tickets.key` 下发。旧密钥签出的票随之作废。
  public func rotateKey() -> String {
    let fresh = SymmetricKey(size: .bits256)
    key.withLock { $0 = fresh }
    return fresh.withUnsafeBytes { Self.hex($0) }
  }

  /// 作废当前密钥（broker 关闭时调用）。之后 `mint` 返回 nil。
  public func revoke() {
    key.withLock { $0 = nil }
  }

  /// 用当前密钥签一张新票；没有密钥时返回 nil。
  public func mint(now: Date = Date()) -> String? {
    guard let current = key.withLock({ $0 }) else { return nil }
    var generator = SystemRandomNumberGenerator()
    let nonce = Self.hex((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    let expiry = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
      + Int64(Self.lifetime.components.seconds) * 1000
    return Self.ticket(key: current, nonce: nonce, expiryMilliseconds: expiry)
  }

  /// 按给定密钥、nonce 与到期时间签票。纯函数，测试用它与 Rust 侧的格式对照。
  public static func ticket(key: SymmetricKey, nonce: String, expiryMilliseconds: Int64) -> String {
    let message = Data("v1|\(nonce)|\(expiryMilliseconds)".utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
    return "v1.\(nonce).\(expiryMilliseconds).\(hex(Data(mac)))"
  }

  /// 字节序列转小写 hex。
  static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}

/// 全局签发入口与注入规则。App 启动时注册签发闭包；AsterCore 里的进程启动点只经这里取票。
public enum NativeSSHTicketing {
  /// client 读取票据的环境变量（PROTOCOL §3）。
  public static let environmentKey = "ASTER_SSH_TICKET"

  /// 签发闭包。没有注册（测试、CLI、OpenSSH 引擎）时不签票。
  private static let provider = OSAllocatedUnfairLock<(@Sendable () -> String?)?>(initialState: nil)

  /// 注册或清除签发闭包。App 启动时调用一次。
  public static func install(_ mint: (@Sendable () -> String?)?) {
    provider.withLock { $0 = mint }
  }

  /// 经注册的闭包签一张票；没有注册或 broker 不可用时返回 nil。
  public static func mint() -> String? {
    provider.withLock { $0 }?()
  }

  /// 这次启动是不是 `aster-ssh client`：可执行文件名为 aster-ssh 且第一个参数是 client。
  /// `config` 等其它子命令不连 broker，不需要票据。
  public static func isNativeClientLaunch(executablePath: String, arguments: [String]) -> Bool {
    URL(fileURLWithPath: executablePath).lastPathComponent == "aster-ssh"
      && arguments.first == "client"
  }

  /// 只含票据的附加环境：`aster-ssh client` 时为 `[ASTER_SSH_TICKET: 新票]`，其余为空。
  /// 每次调用都签新票，调用方必须在真正拉起进程前现取。
  public static func launchEnvironment(
    executablePath: String, arguments: [String], mint: () -> String? = NativeSSHTicketing.mint
  ) -> [String: String] {
    guard isNativeClientLaunch(executablePath: executablePath, arguments: arguments),
      let ticket = mint()
    else { return [:] }
    return [environmentKey: ticket]
  }

  /// 子进程的完整环境：先去掉继承来的票据变量（票据只能给本次拉起的 client），
  /// 再为 `aster-ssh client` 合入一张新票。
  public static func environment(
    _ base: [String: String], executablePath: String, arguments: [String],
    mint: () -> String? = NativeSSHTicketing.mint
  ) -> [String: String] {
    var environment = base
    environment[environmentKey] = nil
    environment.merge(
      launchEnvironment(executablePath: executablePath, arguments: arguments, mint: mint)
    ) { _, fresh in fresh }
    return environment
  }
}
