import Foundation

// 私钥保险库里一把密钥的公开元数据。
//
// 私钥本身只在登录钥匙串（service `io.aster.ssh-vault`，账户 = `id`），这里只有公钥、
// 指纹与显示用信息，可以放心写进 `ssh-keys.json`。主机配置按 `id` 引用它。

/// 保险库密钥的公开元数据。
public struct SSHVaultKey: Codable, Equatable, Identifiable, Sendable {
  /// 密钥来源。
  public enum Origin: String, Codable, Sendable {
    /// 在 Aster 里生成。
    case generated
    /// 从私钥文件导入。
    case imported
  }

  /// 钥匙串账户名，也是主机引用它的键。
  public let id: UUID
  /// 用户起的名字。
  public var label: String
  /// SSH 算法名，如 `ssh-ed25519`、`ssh-rsa`、`ecdsa-sha2-nistp256`。
  public var algorithm: String
  /// `SHA256:…` 指纹，与 `ssh-keygen -l` 一致。
  public var fingerprint: String
  /// OpenSSH 一行公钥（含注释）。
  public var publicKey: String
  public var comment: String
  public var createdAt: Date
  public var origin: Origin
  /// 导入时的原文件路径，仅用于提示与迁移引用；生成的密钥为 nil。
  public var importedFrom: String?

  public init(
    id: UUID = UUID(),
    label: String,
    algorithm: String,
    fingerprint: String,
    publicKey: String,
    comment: String = "",
    createdAt: Date = Date(),
    origin: Origin,
    importedFrom: String? = nil
  ) {
    self.id = id
    self.label = label
    self.algorithm = algorithm
    self.fingerprint = fingerprint
    self.publicKey = publicKey
    self.comment = comment
    self.createdAt = createdAt
    self.origin = origin
    self.importedFrom = importedFrom
  }

  /// 发给 broker 的引用：只含 ID 与公钥，私钥由 broker 按需经 `auth.request` 索取。
  public var reference: SSHVaultKeyReference {
    SSHVaultKeyReference(id: id, publicKey: publicKey)
  }
}

/// 解析后规格里的一把保险库密钥（`PROTOCOL.md` §4.3 `vaultKeys`）。
public struct SSHVaultKeyReference: Codable, Equatable, Hashable, Sendable {
  public var id: UUID
  /// OpenSSH 一行公钥；broker 用它核对 App 回答的私钥是否是同一把。
  public var publicKey: String

  public init(id: UUID, publicKey: String) {
    self.id = id
    self.publicKey = publicKey
  }
}
