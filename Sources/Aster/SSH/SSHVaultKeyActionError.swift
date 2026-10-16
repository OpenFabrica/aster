import AsterCore
import Foundation

// 私钥保险库动作的错误与错误文案。`SSHVaultKeyActions` 与「主机 → 密钥」页共用，
// 同一种失败只有一句话。

/// 密钥动作失败的原因。文案直接给用户看。
enum SSHVaultKeyActionError: Error, Equatable {
  case invalidPayload
  case unknownKey
  case invalidLabel
  case invalidComment
  case invalidKeyFile
  case runtimeMissing
  case notImported
  case originalMissing
  case verificationFailed
  case originalChanged
  case originalUnverifiable
  case originalOutsideSSHDirectory

  /// 给用户看的一句话。
  var message: String {
    switch self {
    case .invalidPayload: L("密钥参数无效")
    case .unknownKey: L("密钥不存在，可能已被删除")
    case .invalidLabel: L("名称不能为空，不能超过 64 字节，也不能包含换行")
    case .invalidComment: L("注释不能超过 256 字节，也不能包含换行")
    case .invalidKeyFile: L("文件过大或不是文本私钥")
    case .runtimeMissing: L("找不到 aster-ssh，请重新构建 Aster.app")
    case .notImported: L("这把密钥不是从文件导入的")
    case .originalMissing: L("原私钥文件已不存在")
    case .verificationFailed: L("钥匙串里的私钥与记录的指纹不一致，已取消删除原文件")
    case .originalChanged: L("原私钥文件已被改动，与保险库里的密钥不是同一把，已取消删除")
    case .originalUnverifiable: L("原私钥文件已加密，且旁边没有能对上指纹的 .pub 文件，无法确认是同一把密钥，已取消删除")
    case .originalOutsideSSHDirectory: L("原私钥文件不在 ~/.ssh 目录下，Aster 不会删除它，请手动删除")
    }
  }
}

extension SSHVaultKeyActions {
  /// 把各类错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SSHVaultKeyActionError: return error.message
    case SSHVaultKeyToolError.encrypted: return L("私钥已加密，需要 passphrase")
    case SSHVaultKeyToolError.wrongPassphrase: return L("passphrase 不正确")
    case SSHVaultKeyToolError.invalid: return L("不是可识别的私钥文件")
    case SSHVaultKeyToolError.unsupported: return L("不支持这种私钥格式或算法（支持 Ed25519、RSA、ECDSA）")
    case SSHVaultKeyToolError.runtime, SSHVaultKeyToolError.malformedOutput:
      return L("aster-ssh 运行失败")
    case SSHVaultKeyDirectoryError.unknownKey: return SSHVaultKeyActionError.unknownKey.message
    case SSHVaultKeyDirectoryError.keychain(.keychain(let status)),
      SSHVaultKeyDirectoryError.keychainCleanupFailed(.keychain(let status)):
      return L("钥匙串操作失败（\(String(status))）")
    case SSHVaultKeyDirectoryError.store(.invalidKeys(let reasons)):
      if reasons.contains(where: { $0.hasSuffix("duplicate fingerprint") }) {
        return L("这把密钥已在保险库中")
      }
      return L("密钥信息无效：\(reasons.joined(separator: "；"))")
    case SSHVaultKeyDirectoryError.store(let error): return L("读写 ssh-keys.json 失败：\(String(describing: error))")
    case SSHCredentialStoreError.keychain(let status): return L("钥匙串操作失败（\(String(status))）")
    default: return SSHHostEditing.describe(error)
    }
  }
}
