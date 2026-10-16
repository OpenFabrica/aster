import Foundation

// 主机系统信息的持久化：`~/Library/Application Support/Aster/host-facts.json`。
// 与 hosts.json 分开存：它是采集结果、可以随时丢弃重采，不该混进用户手写的主机配置；
// 文件损坏按空处理，不影响主机列表。

/// host-facts.json 的根对象。
struct SSHHostFactsDocument: Codable {
  static let currentVersion = 1
  var version: Int
  var facts: [UUID: SSHHostSystemFacts]
}

/// 主机系统信息存储。线程安全：锁保护最后有效快照。
public final class SSHHostFactsStore: @unchecked Sendable {
  /// 默认路径：与 hosts.json 同目录。
  public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    SSHHostStore.defaultFileURL(fileManager: fileManager).deletingLastPathComponent()
      .appendingPathComponent("host-facts.json")
  }

  public let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var lastValid: [UUID: SSHHostSystemFacts] = [:]

  public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
  }

  /// 最后一份有效内容。
  public var effectiveFacts: [UUID: SSHHostSystemFacts] {
    lock.lock()
    defer { lock.unlock() }
    return lastValid
  }

  /// 从磁盘加载。文件不存在或损坏都按空处理：采集结果丢了可以重采，不值得报错。
  @discardableResult
  public func load() -> [UUID: SSHHostSystemFacts] {
    var facts: [UUID: SSHHostSystemFacts] = [:]
    if let data = try? Data(contentsOf: fileURL),
      let document = try? Self.decoder.decode(SSHHostFactsDocument.self, from: data),
      document.version <= SSHHostFactsDocument.currentVersion
    {
      facts = document.facts
    }
    lock.lock()
    lastValid = facts
    lock.unlock()
    return facts
  }

  /// 原子写入并替换快照。
  public func save(_ facts: [UUID: SSHHostSystemFacts]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(SSHHostFactsDocument(version: SSHHostFactsDocument.currentVersion, facts: facts))
    try PrivateFileWriter.write(data, to: fileURL, fileManager: fileManager)
    lock.lock()
    lastValid = facts
    lock.unlock()
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
