// 网页工具的加密存储：`<PluginData>/<id>/secure-storage.bin`。接口与 `storage.*` 相同，
// 整份 JSON 用 AES-GCM 加密后原子写入，密钥在钥匙串（ToolSecureStorageKeychain）。
// 文件格式：4 字节魔数 `AST1` + AES.GCM 合并密文（nonce + 密文 + tag），附加数据是插件 id，换插件就解不开。
import AsterCore
import CryptoKit
import Foundation

/// 单个插件的加密键值存储。同一数据目录在进程内只有一个实例，读改写在 actor 里串行。
/// 只有 Aster 写这个文件（脚本工具拿不到密钥），所以读一次后一直用内存缓存。
actor ToolPluginSecureStorage {
  static let fileName = "secure-storage.bin"
  /// 解不开的旧文件改名成这个留底，然后按空存储继续。
  static let quarantineFileName = "secure-storage.bin.bad"
  static let magic = Data("AST1".utf8)

  let fileURL: URL
  let pluginID: String
  private let keyStore: any ToolSecureStorageKeyStoring
  private var cache: [String: JSONValue]?
  /// 已从钥匙串取到或新建的密钥。
  private var key: SymmetricKey?

  /// `directory` 是插件数据目录，可以尚未创建。
  init(directory: URL, pluginID: String, keyStore: any ToolSecureStorageKeyStoring) {
    fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    self.pluginID = pluginID
    self.keyStore = keyStore
  }

  /// 读一个值；不存在时返回 null。
  func value(forKey key: String) throws -> JSONValue {
    try load()[key] ?? .null
  }

  /// 写一个值。明文 JSON 超过总量上限时拒绝，原内容不变。
  func setValue(_ value: JSONValue, forKey key: String) throws {
    var values = try load()
    values[key] = value
    try save(values)
  }

  /// 删除一个值；本来就没有时什么也不做。
  func removeValue(forKey key: String) throws {
    var values = try load()
    guard values.removeValue(forKey: key) != nil else { return }
    try save(values)
  }

  /// 全部 key，按字典序。
  func keys() throws -> [String] {
    try load().keys.sorted()
  }

  // MARK: - 读写

  /// 读当前内容：有缓存用缓存；文件不存在视为空；解不开（密钥丢失、文件损坏或被换）就挪走留底，按空处理。
  /// 钥匙串本身访问失败（被拒、未解锁）直接报错，不动文件，免得一次临时失败毁掉数据。
  private func load() throws -> [String: JSONValue] {
    if let cache { return cache }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      cache = [:]
      return [:]
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ToolBridgeError.failed(L("无法读取加密存储"))
    }
    guard let key = try existingKey() else {
      try quarantine(reason: "missing_key")
      return [:]
    }
    guard let values = Self.decrypt(data, key: key, pluginID: pluginID) else {
      try quarantine(reason: "decrypt_failed")
      return [:]
    }
    cache = values
    return values
  }

  /// 加密后原子写入；明文超过上限抛 `payload_too_large`，不落盘。
  private func save(_ values: [String: JSONValue]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let plaintext: Data
    do {
      plaintext = try encoder.encode(JSONValue.object(values))
    } catch {
      throw ToolBridgeError.failed(L("无法写入加密存储"))
    }
    guard plaintext.count <= ToolBridgeProtocol.maximumStorageBytes else { throw ToolBridgeError.payloadTooLarge }
    let sealed: Data
    do {
      sealed = try Self.encrypt(plaintext, key: try keyForWriting(), pluginID: pluginID)
    } catch let error as ToolBridgeError {
      throw error
    } catch {
      throw ToolBridgeError.failed(L("无法写入加密存储"))
    }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try sealed.write(to: fileURL, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      throw ToolBridgeError.failed(L("无法写入加密存储"))
    }
    cache = values
  }

  /// 把解不开的文件改名留底（覆盖上一次的留底），记一条诊断，之后按空存储使用。
  private func quarantine(reason: String) throws {
    let destination = fileURL.deletingLastPathComponent().appendingPathComponent(Self.quarantineFileName)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: fileURL, to: destination)
    } catch {
      throw ToolBridgeError.failed(L("无法读取加密存储"))
    }
    DiagnosticsCenter.shared.record(
      "tools.secure_storage_quarantined", level: .warning, category: .storage,
      attributes: ["plugin": pluginID, "reason": reason])
    cache = [:]
  }

  // MARK: - 密钥

  /// 钥匙串里可用的密钥；没有返回 nil。不可信的条目当作没有并删掉（数据随之挪走，见 `load()`）。
  private func existingKey() throws -> SymmetricKey? {
    if let key { return key }
    do {
      guard let data = try keyStore.loadKey(pluginID: pluginID) else { return nil }
      guard data.count == 32 else { return nil }
      let loaded = SymmetricKey(data: data)
      key = loaded
      return loaded
    } catch ToolSecureStorageKeyError.untrustedAccess {
      DiagnosticsCenter.shared.record(
        "tools.secure_storage_untrusted_key", level: .warning, category: .storage, attributes: ["plugin": pluginID])
      try deleteKey()
      return nil
    } catch {
      throw ToolBridgeError.failed(L("无法访问钥匙串"))
    }
  }

  /// 写入要用的密钥：已有就用，没有就新建一把存进钥匙串。
  private func keyForWriting() throws -> SymmetricKey {
    if let key = try existingKey() { return key }
    let created = SymmetricKey(size: .bits256)
    do {
      try keyStore.saveKey(created.withUnsafeBytes { Data($0) }, pluginID: pluginID)
    } catch {
      throw ToolBridgeError.failed(L("无法访问钥匙串"))
    }
    key = created
    return created
  }

  /// 删除钥匙串里的条目。
  private func deleteKey() throws {
    do {
      try keyStore.deleteKey(pluginID: pluginID)
    } catch {
      throw ToolBridgeError.failed(L("无法访问钥匙串"))
    }
  }

  // MARK: - 加解密

  /// 魔数 + AES-GCM 合并密文；附加数据绑定插件 id。
  static func encrypt(_ plaintext: Data, key: SymmetricKey, pluginID: String) throws -> Data {
    let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(pluginID.utf8))
    guard let combined = box.combined else { throw ToolBridgeError.failed(L("无法写入加密存储")) }
    return magic + combined
  }

  /// 解开并解析成 JSON 对象；魔数不对、认证失败或内容不是对象都返回 nil。
  static func decrypt(_ data: Data, key: SymmetricKey, pluginID: String) -> [String: JSONValue]? {
    guard data.starts(with: magic) else { return nil }
    do {
      let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
      let plaintext = try AES.GCM.open(box, using: key, authenticating: Data(pluginID.utf8))
      guard case .object(let values) = try JSONDecoder().decode(JSONValue.self, from: plaintext) else { return nil }
      return values
    } catch {
      return nil
    }
  }
}

// MARK: - 共享实例

extension ToolPluginSecureStorage {
  /// 弱引用包装：没有页面在用时实例随之释放，内存里的明文缓存与密钥也随之释放。
  @MainActor
  private final class WeakBox {
    weak var storage: ToolPluginSecureStorage?

    init(_ storage: ToolPluginSecureStorage) {
      self.storage = storage
    }
  }

  /// 数据目录路径 → 正在使用的实例。
  @MainActor private static var instances: [String: WeakBox] = [:]

  /// 取某个数据目录的共享实例；同一目录在进程内只有一个，保证读改写串行。`keyStore` 只在新建实例时生效。
  @MainActor
  static func shared(
    for directory: URL, pluginID: String, keyStore: any ToolSecureStorageKeyStoring
  ) -> ToolPluginSecureStorage {
    let key = directory.standardizedFileURL.path
    if let existing = instances[key]?.storage { return existing }
    instances = instances.filter { $0.value.storage != nil }
    let storage = ToolPluginSecureStorage(directory: directory, pluginID: pluginID, keyStore: keyStore)
    instances[key] = WeakBox(storage)
    return storage
  }
}
