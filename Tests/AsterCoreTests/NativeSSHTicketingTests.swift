import CryptoKit
import Foundation
import Testing

@testable import AsterCore

// 启动票据：签发格式、密钥轮换与作废、环境注入只给 `aster-ssh client`。
// 格式向量与 SshRuntime/src/tickets.rs 的 `the_ticket_format_matches_the_swift_issuer` 相同。

/// 测：固定密钥、nonce 与到期时间签出的票据与 Rust 侧逐字相同。
@Test func nativeSSHTicketMatchesTheRustVector() {
  let key = SymmetricKey(data: Data(repeating: 7, count: 32))
  let ticket = NativeSSHTicketIssuer.ticket(
    key: key, nonce: "0123456789abcdef0123456789abcdef", expiryMilliseconds: 1_700_000_000_000)
  #expect(
    ticket
      == "v1.0123456789abcdef0123456789abcdef.1700000000000."
      + "530b76c7da3be207734f661ff80a1765a8ea03cf88e648547d6acd226a050a56")
}

/// 测：没有密钥不签票；轮换后签出 120 秒有效、nonce 各不相同、用当前密钥签名的票；作废后不再签。
@Test func nativeSSHTicketIssuerRotatesMintsAndRevokes() throws {
  let issuer = NativeSSHTicketIssuer()
  #expect(issuer.mint() == nil)

  let hexKey = issuer.rotateKey()
  #expect(hexKey.count == 64)
  #expect(hexKey.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let first = try #require(issuer.mint(now: now))
  let second = try #require(issuer.mint(now: now))
  let parts = first.split(separator: ".").map(String.init)
  #expect(parts.count == 4)
  #expect(parts[0] == "v1")
  #expect(parts[1].count == 32)
  #expect(parts[2] == "1700000120000")
  #expect(first.split(separator: ".")[1] != second.split(separator: ".")[1])
  let keyBytes = try #require(Data(hexString: hexKey))
  #expect(
    first
      == NativeSSHTicketIssuer.ticket(
        key: SymmetricKey(data: keyBytes), nonce: parts[1], expiryMilliseconds: 1_700_000_120_000))

  #expect(issuer.rotateKey() != hexKey)
  issuer.revoke()
  #expect(issuer.mint() == nil)
}

/// 测：只有 `aster-ssh client` 拿到票据；继承来的票据变量总被去掉；没有签发者时不注入。
@Test func nativeSSHTicketingInjectsOnlyIntoNativeClients() {
  let mint: () -> String? = { "v1.fresh" }
  let base = ["PATH": "/usr/bin", NativeSSHTicketing.environmentKey: "v1.stale"]
  let client = NativeSSHTicketing.environment(
    base, executablePath: "/Apps/Aster.app/Contents/MacOS/aster-ssh",
    arguments: ["client", "--broker", "/tmp/b.sock"], mint: mint)
  #expect(client[NativeSSHTicketing.environmentKey] == "v1.fresh")
  #expect(client["PATH"] == "/usr/bin")

  let config = NativeSSHTicketing.environment(
    base, executablePath: "/x/aster-ssh", arguments: ["config", "list"], mint: mint)
  #expect(config[NativeSSHTicketing.environmentKey] == nil)
  let openssh = NativeSSHTicketing.environment(
    base, executablePath: "/usr/bin/ssh", arguments: ["client"], mint: mint)
  #expect(openssh[NativeSSHTicketing.environmentKey] == nil)
  #expect(openssh["PATH"] == "/usr/bin")
  let unavailable = NativeSSHTicketing.environment(
    base, executablePath: "/x/aster-ssh", arguments: ["client"], mint: { nil })
  #expect(unavailable[NativeSSHTicketing.environmentKey] == nil)

  #expect(
    NativeSSHTicketing.launchEnvironment(
      executablePath: "/x/aster-ssh", arguments: ["client"], mint: mint)
      == [NativeSSHTicketing.environmentKey: "v1.fresh"])
  #expect(
    NativeSSHTicketing.launchEnvironment(
      executablePath: "/x/aster-session", arguments: ["client"], mint: mint
    ).isEmpty)
}

/// 测：真实执行器拉起 `aster-ssh client` 时经环境变量交出新票据，拉起别的程序时不交。
///
/// 用名为 aster-ssh 的假脚本打印收到的变量；注册的全局签发者在用例结束时清除。
@Test func nativeSSHRunnersHandTicketsOnlyToNativeClients() throws {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AsterTicketRunner.\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = "#!/bin/sh\nprintf '%s' \"${ASTER_SSH_TICKET:-none}\"\n"
  let native = directory.appendingPathComponent("aster-ssh")
  let other = directory.appendingPathComponent("not-aster")
  for url in [native, other] {
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
  NativeSSHTicketing.install { "v1.runner-ticket" }
  defer { NativeSSHTicketing.install(nil) }

  let runner = RemoteSSHProcessRunner(executablePath: native.path)
  #expect(try runner.run(arguments: ["client", "--broker", "/tmp/x"], timeout: 5).standardOutput
    == "v1.runner-ticket")
  #expect(try runner.run(arguments: ["config", "list"], timeout: 5).standardOutput == "none")
  let plain = RemoteSSHProcessRunner(executablePath: other.path)
  #expect(try plain.run(arguments: ["client"], timeout: 5).standardOutput == "none")

  let stream = RemoteSSHStreamRunner(executablePath: native.path)
  let streamed = try stream.stream(
    arguments: ["client", "--broker", "/tmp/x"], stdinFile: nil, stdoutFile: nil,
    maximumBytes: 1024, timeout: 5)
  #expect(streamed.standardOutput == "v1.runner-ticket")
}

extension Data {
  /// 小写或大写 hex 文本转字节；长度为奇数或含非 hex 字符时返回 nil。仅测试使用。
  fileprivate init?(hexString: String) {
    guard hexString.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
