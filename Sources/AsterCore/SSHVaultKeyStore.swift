import Foundation
import os

// 私钥保险库目录的持久化：`~/Library/Application Support/Aster/ssh-keys.json`。
//
// 规则与 `SSHHostStore` 一致：整份校验通过才替换有效快照；文件不存在与内容损坏是两种结果；
// 写入走 `PrivateFileWriter`（目录 0700、文件 0600）。文件里只有公钥与显示信息，
// 私钥只在钥匙串里，类型层面就不存在私钥字段。

/// 保险库目录存储错误，全部可恢复：调用方保留最后有效快照即可。
public enum SSHVaultKeyStoreError: Error, Equatable, Sendable {
  case corrupted(detail: String)
  case invalidKeys(reasons: [String])
  case ioFailure(detail: String)
}

/// ssh-keys.json 的根对象。带版本号，便于以后迁移。
struct SSHVaultKeyDocument: Codable, Equatable {
  static let currentVersion = 1
  var version: Int
  var keys: [SSHVaultKey]
}

/// 保险库目录存储。线程安全：锁保护最后有效快照，不持有其它可变状态。
public final class SSHVaultKeyStore: Sendable {
  /// 名称的最大 UTF-8 字节数。
  public static let maximumLabelBytes = 64
  /// 保险库最多保存的密钥数；远大于正常用量，只挡异常文件。
  public static let maximumKeys = 256
  /// 公钥行可接受的算法前缀，与 `aster-ssh keys` 能导入的类型一致。
  public static let supportedAlgorithms = [
    "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
  ]

  /// 默认路径：`~/Library/Application Support/Aster/ssh-keys.json`。
  public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    SSHHostStore.defaultFileURL(fileManager: fileManager)
      .deletingLastPathComponent().appendingPathComponent("ssh-keys.json")
  }

  public let fileURL: URL
  private let lastValid = OSAllocatedUnfairLock(initialState: [SSHVaultKey]())

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
  }

  /// 最后一份有效快照。
  public var effectiveKeys: [SSHVaultKey] { lastValid.withLock { $0 } }

  /// 从磁盘加载。文件不存在时返回空列表（合法的首次启动）。
  @discardableResult
  public func load() throws -> [SSHVaultKey] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return replaceSnapshot([]) }
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch {
      throw SSHVaultKeyStoreError.ioFailure(detail: String(describing: error))
    }
    return replaceSnapshot(try Self.decode(data))
  }

  /// 原子写入并替换有效快照。写入前整份校验，非法内容不会落盘。
  public func save(_ keys: [SSHVaultKey]) throws {
    let normalized = Self.normalized(keys)
    let reasons = Self.validate(normalized)
    guard reasons.isEmpty else { throw SSHVaultKeyStoreError.invalidKeys(reasons: reasons) }
    let data = try Self.encode(normalized)
    do {
      try PrivateFileWriter.write(data, to: fileURL)
    } catch {
      throw SSHVaultKeyStoreError.ioFailure(detail: String(describing: error))
    }
    replaceSnapshot(normalized)
  }

  /// 替换有效快照并原样返回。
  @discardableResult
  private func replaceSnapshot(_ keys: [SSHVaultKey]) -> [SSHVaultKey] {
    lastValid.withLock { $0 = keys }
    return keys
  }

  // MARK: - 编解码与校验

  /// 日期统一用 ISO 8601 文本，便于人工查看。
  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// 解码并整份校验。解析失败与内容非法分成两种错误。
  public static func decode(_ data: Data) throws -> [SSHVaultKey] {
    guard !data.isEmpty else { throw SSHVaultKeyStoreError.corrupted(detail: "empty file") }
    let document: SSHVaultKeyDocument
    do { document = try makeDecoder().decode(SSHVaultKeyDocument.self, from: data) } catch {
      throw SSHVaultKeyStoreError.corrupted(detail: String(describing: error))
    }
    guard document.version <= SSHVaultKeyDocument.currentVersion else {
      throw SSHVaultKeyStoreError.corrupted(detail: "unsupported version \(document.version)")
    }
    let keys = normalized(document.keys)
    let reasons = validate(keys)
    guard reasons.isEmpty else { throw SSHVaultKeyStoreError.invalidKeys(reasons: reasons) }
    return keys
  }

  /// 编码成带版本号的稳定 JSON（键排序）。
  public static func encode(_ keys: [SSHVaultKey]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
      return try encoder.encode(SSHVaultKeyDocument(version: SSHVaultKeyDocument.currentVersion, keys: keys))
    } catch {
      throw SSHVaultKeyStoreError.ioFailure(detail: String(describing: error))
    }
  }

  /// 规范化：名称与公钥去首尾空白。
  public static func normalized(_ keys: [SSHVaultKey]) -> [SSHVaultKey] {
    keys.map { key in
      var copy = key
      copy.label = copy.label.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.publicKey = copy.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
      return copy
    }
  }

  /// 逐条校验，返回全部原因；空数组表示合法。
  ///
  /// 指纹唯一：同一把私钥只存一份，导入重复的文件会复用已有条目，而不是在钥匙串里留两份。
  public static func validate(_ keys: [SSHVaultKey]) -> [String] {
    var reasons: [String] = []
    if keys.count > maximumKeys { reasons.append("too many keys") }
    var ids: Set<UUID> = []
    var fingerprints: Set<String> = []
    for (index, key) in keys.enumerated() {
      let tag = "[\(index)]"
      if !ids.insert(key.id).inserted { reasons.append("\(tag) duplicate id") }
      if !fingerprints.insert(key.fingerprint).inserted { reasons.append("\(tag) duplicate fingerprint") }
      if key.label.isEmpty || key.label.utf8.count > maximumLabelBytes || hasControl(key.label) {
        reasons.append("\(tag) invalid label")
      }
      if !key.fingerprint.hasPrefix("SHA256:") || hasControl(key.fingerprint) {
        reasons.append("\(tag) invalid fingerprint")
      }
      if !isParseablePublicKey(key.publicKey, algorithm: key.algorithm) {
        reasons.append("\(tag) invalid public key")
      }
      if hasControl(key.comment) || hasControl(key.importedFrom ?? "") {
        reasons.append("\(tag) control characters")
      }
    }
    return reasons
  }

  /// 公钥行至少是「算法 base64 [注释]」，算法受支持且与元数据一致；base64 必须能解码。
  public static func isParseablePublicKey(_ line: String, algorithm: String) -> Bool {
    guard !hasControl(line) else { return false }
    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2, supportedAlgorithms.contains(String(parts[0])),
      String(parts[0]) == algorithm
    else { return false }
    return Data(base64Encoded: String(parts[1])) != nil
  }

  /// 是否含换行等控制字符。
  static func hasControl(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}
