import Foundation
import Testing

@testable import Aster

// SSHVaultKeyTool：错误 JSON 的映射，以及对真实 aster-ssh 的 generate → inspect 往返。
// 真实二进制由 `./scripts/build-ssh-runtime.sh .build/debug` 或 cargo 构建；都不存在时跳过往返用例。

/// 仓库里已构建的 aster-ssh（`.build/debug` 优先，其次 cargo 调试产物）。
private let builtRuntime: URL? = {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  return ["/.build/debug/aster-ssh", "/SshRuntime/target/debug/aster-ssh"]
    .map { URL(fileURLWithPath: root.path + $0) }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}()

@Test("keys 的错误 JSON 映射成对应错误；未知码按 invalid，非 JSON 按输出异常")
func sshVaultKeyToolMapsFailures() {
  #expect(SSHVaultKeyTool.mapFailure(Data(#"{"error":"encrypted"}"#.utf8)) == .encrypted)
  #expect(SSHVaultKeyTool.mapFailure(Data(#"{"error":"wrongPassphrase"}"#.utf8)) == .wrongPassphrase)
  #expect(SSHVaultKeyTool.mapFailure(Data(#"{"error":"unsupported"}"#.utf8)) == .unsupported)
  #expect(SSHVaultKeyTool.mapFailure(Data(#"{"error":"whatever"}"#.utf8)) == .invalid)
  #expect(SSHVaultKeyTool.mapFailure(Data("oops".utf8)) == .malformedOutput)
}

@Test("真实 aster-ssh：生成的私钥经 inspect 得到同一指纹，注释可覆盖", .enabled(if: builtRuntime != nil))
func sshVaultKeyToolRoundTripsWithRealRuntime() async throws {
  let tool = SSHVaultKeyTool(runtime: SSHRuntimeTool(executableURL: try #require(builtRuntime)))
  let generated = try await tool.generate(comment: "aster-test")
  #expect(generated.algorithm == "ssh-ed25519")
  #expect(generated.fingerprint.hasPrefix("SHA256:"))
  #expect(generated.publicKey.hasSuffix(" aster-test"))
  #expect(generated.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))

  let inspected = try await tool.inspect(
    privateKey: generated.privateKey, passphrase: nil, comment: "renamed")
  #expect(inspected.fingerprint == generated.fingerprint)
  #expect(inspected.comment == "renamed")

  await #expect(throws: SSHVaultKeyToolError.invalid) {
    try await tool.inspect(privateKey: "not a key", passphrase: nil, comment: nil)
  }
}
