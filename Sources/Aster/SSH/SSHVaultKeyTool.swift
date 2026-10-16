import Foundation

// `aster-ssh keys inspect|generate` 的调用封装（`SshRuntime/PROTOCOL.md` §6）。
// 私钥与 passphrase 只经 stdin 传入，结果从 stdout 读回；这里不记录任何输入输出。
// Swift `String` 无法清零：拿到的私钥文本只在调用链上短暂存在，不存进任何属性。

/// `aster-ssh keys` 的一次成功结果。
struct SSHVaultKeyMaterial: Decodable, Equatable, Sendable {
  /// 未加密的 OpenSSH 私钥文本（LF 换行）。
  var privateKey: String
  /// OpenSSH 一行公钥（注释非空时含注释）。
  var publicKey: String
  var algorithm: String
  var fingerprint: String
  var comment: String
}

/// `aster-ssh keys` 的失败。
enum SSHVaultKeyToolError: Error, Equatable {
  /// 私钥已加密，需要 passphrase。
  case encrypted
  /// passphrase 不对。
  case wrongPassphrase
  /// 不是可识别的私钥。
  case invalid
  /// 格式或算法不支持（DSA、安全密钥、旧式 DES PEM 等）。
  case unsupported
  /// 运行器本身失败（找不到程序、超时、输出异常）。
  case runtime(SSHRuntimeToolError)
  /// 输出不是约定的 JSON。
  case malformedOutput
}

/// `keys` 子命令的调用边界，测试可以换成替身。
protocol SSHVaultKeyTooling: Sendable {
  /// 解析并规范化一把私钥；加密时需要 passphrase。`comment` 非空时覆盖私钥自带的注释。
  func inspect(privateKey: String, passphrase: String?, comment: String?) async throws
    -> SSHVaultKeyMaterial
  /// 生成一把新的 ed25519 私钥。
  func generate(comment: String) async throws -> SSHVaultKeyMaterial
}

/// 用 `SSHRuntimeTool` 运行 `aster-ssh keys`。
struct SSHVaultKeyTool: SSHVaultKeyTooling {
  let runtime: SSHRuntimeTool

  /// 运行 `keys inspect`。
  func inspect(privateKey: String, passphrase: String?, comment: String?) async throws
    -> SSHVaultKeyMaterial
  {
    struct Request: Encodable {
      var privateKey: String
      var passphrase: String?
      var comment: String?
      // 显式写出 null，与协议示例一致。
      func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privateKey, forKey: .privateKey)
        try container.encode(passphrase, forKey: .passphrase)
        try container.encode(comment, forKey: .comment)
      }
      enum CodingKeys: String, CodingKey { case privateKey, passphrase, comment }
    }
    let input = try JSONEncoder().encode(
      Request(privateKey: privateKey, passphrase: passphrase, comment: comment))
    return try await run(["keys", "inspect"], input: input)
  }

  /// 运行 `keys generate`。
  func generate(comment: String) async throws -> SSHVaultKeyMaterial {
    struct Request: Encodable {
      var algorithm = "ed25519"
      var comment: String
    }
    let input = try JSONEncoder().encode(Request(comment: comment))
    return try await run(["keys", "generate"], input: input)
  }

  /// 执行并把退出码 1 的错误 JSON 映射成 `SSHVaultKeyToolError`。
  private func run(_ arguments: [String], input: Data) async throws -> SSHVaultKeyMaterial {
    let output: Data
    do {
      output = try await runtime.run(arguments, input: input)
    } catch let SSHRuntimeToolError.exited(code, stdout) where code == 1 {
      throw Self.mapFailure(stdout)
    } catch let error as SSHRuntimeToolError {
      throw SSHVaultKeyToolError.runtime(error)
    }
    do {
      return try JSONDecoder().decode(SSHVaultKeyMaterial.self, from: output)
    } catch {
      throw SSHVaultKeyToolError.malformedOutput
    }
  }

  /// 解析 `{"error": "…"}`；未知错误码按 `invalid` 处理。
  static func mapFailure(_ stdout: Data) -> SSHVaultKeyToolError {
    struct Failure: Decodable { var error: String }
    let failure: Failure
    do { failure = try JSONDecoder().decode(Failure.self, from: stdout) } catch {
      return .malformedOutput
    }
    switch failure.error {
    case "encrypted": return .encrypted
    case "wrongPassphrase": return .wrongPassphrase
    case "unsupported": return .unsupported
    default: return .invalid
    }
  }
}
