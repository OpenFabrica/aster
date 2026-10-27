// 网页工具的私有存储：`<PluginData>/<id>/storage.json`。值是任意 JSON，总量有上限，写入原子完成。
import AsterCore
import Foundation

/// 单个插件的键值存储。同一数据目录在进程内只有一个实例（见 `shared(for:)`），读改写在 actor 里串行，
/// 工具面板与工具 Pane 同时打开同一插件也不会互相覆盖。
actor ToolPluginStorage {
  static let fileName = "storage.json"

  let fileURL: URL
  /// 最近一次读到或写入的内容。
  private var cache: [String: JSONValue]?
  /// 缓存对应的文件大小与修改时间。脚本工具拿到同一个数据目录，也可能改这个文件，
  /// 所以每次操作前都比对一次，变了就重读。
  private var cacheStamp: FileStamp?

  /// 用文件大小与修改时间判断文件是否被外部改过。
  private struct FileStamp: Equatable {
    let size: Int
    let modified: Date
  }

  /// `directory` 是插件数据目录，可以尚未创建。
  init(directory: URL) {
    fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
  }

  /// 读一个值；不存在时返回 null。
  func value(forKey key: String) throws -> JSONValue {
    try load()[key] ?? .null
  }

  /// 写一个值。写入后的整个文件超过上限时拒绝，原内容不变。
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

  /// 读当前内容：文件没变就用缓存，文件不存在视为空。
  private func load() throws -> [String: JSONValue] {
    let stamp = try currentStamp()
    if let cache, stamp == cacheStamp { return cache }
    guard let stamp else {
      cache = [:]
      cacheStamp = nil
      return [:]
    }
    guard stamp.size <= ToolBridgeProtocol.maximumStorageBytes else {
      throw ToolBridgeError.failed(L("插件存储超出上限"))
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ToolBridgeError.failed(L("无法读取插件存储"))
    }
    let decoded: JSONValue
    do {
      decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw ToolBridgeError.failed(L("插件存储文件已损坏"))
    }
    guard case .object(let values) = decoded else { throw ToolBridgeError.failed(L("插件存储文件已损坏")) }
    cache = values
    cacheStamp = stamp
    return values
  }

  /// 原子写入整份内容；超过总量上限时抛 `payload_too_large`，不落盘。
  private func save(_ values: [String: JSONValue]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(JSONValue.object(values))
    } catch {
      throw ToolBridgeError.failed(L("无法写入插件存储"))
    }
    guard data.count <= ToolBridgeProtocol.maximumStorageBytes else { throw ToolBridgeError.payloadTooLarge }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      throw ToolBridgeError.failed(L("无法写入插件存储"))
    }
    cache = values
    cacheStamp = try currentStamp()
  }

  /// 文件当前的大小与修改时间；文件不存在返回 nil。
  private func currentStamp() throws -> FileStamp? {
    let values: URLResourceValues
    do {
      values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw ToolBridgeError.failed(L("无法读取插件存储"))
    }
    guard values.isRegularFile == true else { throw ToolBridgeError.failed(L("无法读取插件存储")) }
    return FileStamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
  }
}

// MARK: - 共享实例

extension ToolPluginStorage {
  /// 弱引用包装：没有页面在用时存储实例随之释放，缓存不会一直占内存。
  @MainActor
  private final class WeakBox {
    weak var storage: ToolPluginStorage?

    init(_ storage: ToolPluginStorage) {
      self.storage = storage
    }
  }

  /// 数据目录路径 → 正在使用的存储实例。
  @MainActor private static var instances: [String: WeakBox] = [:]

  /// 取某个数据目录的共享实例；同一目录在进程内只有一个，保证读改写串行。
  @MainActor
  static func shared(for directory: URL) -> ToolPluginStorage {
    let key = directory.standardizedFileURL.path
    if let existing = instances[key]?.storage { return existing }
    instances = instances.filter { $0.value.storage != nil }
    let storage = ToolPluginStorage(directory: directory)
    instances[key] = WeakBox(storage)
    return storage
  }
}
