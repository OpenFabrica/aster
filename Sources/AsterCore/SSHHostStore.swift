import Foundation

// 已保存 SSH 主机的持久化：`~/Library/Application Support/Aster/hosts.json`。
//
// 规则与 `MachineProfileStore` 一致：整份校验通过才替换有效快照；文件不存在与内容损坏
// 是两种结果；写入走同目录临时文件 + rename，目录 0700、文件 0600。文件里没有任何秘密字段，
// 类型层面就不存在口令或私钥。

/// 主机存储错误，全部可恢复：调用方保留最后有效快照即可。
public enum SSHHostStoreError: Error, Equatable, Sendable {
  case corrupted(detail: String)
  case invalidHosts(reasons: [String])
  case ioFailure(detail: String)
}

/// hosts.json 的根对象。带版本号，便于以后迁移。
///
/// `groups` 是用户在主机页里明确「新建」或「重命名」过的分组名：分组本身没有实体，平时由
/// 主机的 `group` 字段推出，但空分组也要能显示，所以在这里单独记一份。旧文件没有这个键，
/// 解码成空数组；旧版本读到新文件会忽略它，不需要升版本号。
struct SSHHostDocument: Codable, Equatable {
  static let currentVersion = 1
  var version: Int
  var hosts: [SSHHostProfile]
  var groups: [String]?
}

/// 一份完整的 hosts.json 内容：主机列表与明确声明的分组。
public struct SSHHostSnapshot: Equatable, Sendable {
  /// 主机列表，默认项在第一位。
  public var hosts: [SSHHostProfile]
  /// 明确声明的分组名（已规范化、去重，不含导入组）。
  public var groups: [String]

  public init(hosts: [SSHHostProfile], groups: [String] = []) {
    self.hosts = hosts
    self.groups = groups
  }
}

/// 主机配置存储。线程安全：锁保护最后有效快照。
public final class SSHHostStore: @unchecked Sendable {
  /// 分组名的最大 UTF-8 字节数。
  public static let maximumGroupBytes = 64
  /// 每台主机最多的标签数。
  public static let maximumTags = 16
  /// 单个标签的最大 UTF-8 字节数。
  public static let maximumTagBytes = 32
  /// 一台主机最多引用的保险库密钥数。
  public static let maximumVaultKeys = 16

  /// 默认路径：`~/Library/Application Support/Aster/hosts.json`。
  public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Aster/hosts.json")
  }

  public let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var lastValid = SSHHostSnapshot(hosts: [.emptyDefaults()])

  public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
  }

  /// 最后一份有效快照里的主机，默认项总在第一位。
  public var effectiveHosts: [SSHHostProfile] { effectiveSnapshot.hosts }

  /// 最后一份有效快照里明确声明的分组。
  public var effectiveGroups: [String] { effectiveSnapshot.groups }

  /// 最后一份有效快照。
  public var effectiveSnapshot: SSHHostSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return lastValid
  }

  /// 从磁盘加载。文件不存在时返回只含默认项的列表（合法的首次启动）。
  @discardableResult
  public func load() throws -> [SSHHostProfile] {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return replaceSnapshot(SSHHostSnapshot(hosts: [.emptyDefaults()])).hosts
    }
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch {
      throw SSHHostStoreError.ioFailure(detail: String(describing: error))
    }
    return replaceSnapshot(try Self.decodeSnapshot(data)).hosts
  }

  /// 外部变更入口（文件监听读出内容后交给它）；nil 表示文件被删除。
  @discardableResult
  public func applyExternalChange(data: Data?) throws -> [SSHHostProfile] {
    guard let data else { return replaceSnapshot(SSHHostSnapshot(hosts: [.emptyDefaults()])).hosts }
    return replaceSnapshot(try Self.decodeSnapshot(data)).hosts
  }

  /// 只改主机，声明的分组沿用当前快照。
  public func save(_ hosts: [SSHHostProfile]) throws {
    try save(SSHHostSnapshot(hosts: hosts, groups: effectiveGroups))
  }

  /// 原子写入并替换有效快照。写入前整份校验，非法内容不会落盘。
  public func save(_ snapshot: SSHHostSnapshot) throws {
    let normalized = Self.normalized(snapshot)
    let reasons = Self.validate(normalized)
    guard reasons.isEmpty else { throw SSHHostStoreError.invalidHosts(reasons: reasons) }
    let data = try Self.encode(normalized)
    do {
      try PrivateFileWriter.write(data, to: fileURL, fileManager: fileManager)
    } catch {
      throw SSHHostStoreError.ioFailure(detail: String(describing: error))
    }
    replaceSnapshot(normalized)
  }

  @discardableResult
  private func replaceSnapshot(_ snapshot: SSHHostSnapshot) -> SSHHostSnapshot {
    lock.lock()
    lastValid = snapshot
    lock.unlock()
    return snapshot
  }

  // MARK: - 编解码与校验

  /// 解码并整份校验，只取主机。解析失败与内容非法分成两种错误。
  public static func decode(_ data: Data) throws -> [SSHHostProfile] {
    try decodeSnapshot(data).hosts
  }

  /// 解码并整份校验主机与声明的分组。
  public static func decodeSnapshot(_ data: Data) throws -> SSHHostSnapshot {
    guard !data.isEmpty else { throw SSHHostStoreError.corrupted(detail: "empty file") }
    let document: SSHHostDocument
    do { document = try JSONDecoder().decode(SSHHostDocument.self, from: data) } catch {
      throw SSHHostStoreError.corrupted(detail: String(describing: error))
    }
    guard document.version <= SSHHostDocument.currentVersion else {
      throw SSHHostStoreError.corrupted(detail: "unsupported version \(document.version)")
    }
    let snapshot = normalized(SSHHostSnapshot(hosts: document.hosts, groups: document.groups ?? []))
    let reasons = validate(snapshot)
    guard reasons.isEmpty else { throw SSHHostStoreError.invalidHosts(reasons: reasons) }
    return snapshot
  }

  /// 编码成带版本号的稳定 JSON（键排序，便于人工查看与比较）。
  public static func encode(_ hosts: [SSHHostProfile]) throws -> Data {
    try encode(SSHHostSnapshot(hosts: hosts))
  }

  /// 编码主机与声明的分组；分组为空时不写 `groups` 键，文件与旧版本完全一样。
  public static func encode(_ snapshot: SSHHostSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      return try encoder.encode(
        SSHHostDocument(
          version: SSHHostDocument.currentVersion, hosts: snapshot.hosts,
          groups: snapshot.groups.isEmpty ? nil : snapshot.groups))
    } catch {
      throw SSHHostStoreError.ioFailure(detail: String(describing: error))
    }
  }

  /// 规范化整份快照：主机按 `normalized(_:)`，分组按 `normalizedGroups`。
  public static func normalized(_ snapshot: SSHHostSnapshot) -> SSHHostSnapshot {
    SSHHostSnapshot(hosts: normalized(snapshot.hosts), groups: normalizedGroups(snapshot.groups))
  }

  /// 整理声明的分组：去首尾空白、丢弃空串与导入组（它由导入流程管，不能手工声明）、按原顺序去重。
  public static func normalizedGroups(_ groups: [String]) -> [String] {
    var seen: Set<String> = []
    return groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0 != SSHHostProfile.importedGroup && seen.insert($0).inserted }
  }

  /// 分组名是否合法：不超过 `maximumGroupBytes`，不含换行。主机字段与声明的分组共用。
  public static func groupNameIsValid(_ group: String) -> Bool {
    group.utf8.count <= maximumGroupBytes && !group.contains(where: \.isNewline)
  }

  /// 校验整份快照：主机原因照旧带 `[index]` 前缀，非法分组名报 `groups: invalid group`。
  public static func validate(_ snapshot: SSHHostSnapshot) -> [String] {
    validate(snapshot.hosts)
      + snapshot.groups.filter { !groupNameIsValid($0) }.map { _ in "groups: invalid group" }
  }

  /// 规范化：默认项放到第一位（缺失就补上），分组名去空白、空串变 nil，标签按 `normalizedTags` 整理；
  /// 空的保险库密钥列表变 nil（都表示继承）。
  public static func normalized(_ hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    var defaults = hosts.first { $0.isDefaults } ?? .emptyDefaults()
    defaults.group = nil
    // 默认项不是真实主机，标签对它没有意义，也不参与继承。
    defaults.tags = nil
    if defaults.vaultKeyIDs?.isEmpty == true { defaults.vaultKeyIDs = nil }
    let others = hosts.filter { !$0.isDefaults }.map { profile -> SSHHostProfile in
      var copy = profile
      if copy.vaultKeyIDs?.isEmpty == true { copy.vaultKeyIDs = nil }
      let group = copy.group?.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.group = (group?.isEmpty ?? true) ? nil : group
      copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.host = copy.host.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.user = copy.user.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.tags = normalizedTags(copy.tags)
      return copy
    }
    return [defaults] + others
  }

  /// 整理标签：去首尾空白、丢弃空串、不分大小写去重（保留第一次出现的写法）；结果为空时返回 nil。
  public static func normalizedTags(_ tags: [String]?) -> [String]? {
    guard let tags else { return nil }
    var seen: Set<String> = []
    let result = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    return result.isEmpty ? nil : result
  }

  /// 标签是否合法：数量、单个长度不超限，且不含逗号（网页用逗号分隔输入）、换行或控制字符。
  public static func tagsAreValid(_ tags: [String]?) -> Bool {
    guard let tags else { return true }
    guard tags.count <= maximumTags else { return false }
    return tags.allSatisfy { tag in
      tag.utf8.count <= maximumTagBytes && !tag.contains(",")
        && !tag.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
  }

  /// 逐条校验，返回全部原因；空数组表示合法。
  public static func validate(_ hosts: [SSHHostProfile]) -> [String] {
    var reasons: [String] = []
    var seen: Set<UUID> = []
    let ids = Set(hosts.map(\.id))
    for (index, host) in hosts.enumerated() {
      let tag = "[\(index)]"
      if !seen.insert(host.id).inserted { reasons.append("\(tag) duplicate id") }
      if !host.isDefaults {
        if host.name.isEmpty { reasons.append("\(tag) empty name") }
        if host.host.isEmpty { reasons.append("\(tag) empty host") }
      }
      if host.host.contains(where: \.isNewline) || host.user.contains(where: \.isNewline) {
        reasons.append("\(tag) newline in host/user")
      }
      if let group = host.group, !groupNameIsValid(group) { reasons.append("\(tag) invalid group") }
      if !tagsAreValid(host.tags) { reasons.append("\(tag) invalid tags") }
      if let port = host.port, !(1...65535).contains(port) { reasons.append("\(tag) invalid port") }
      for proxy in [host.socksProxy, host.httpProxy].compactMap({ $0 })
      where !(1...65535).contains(proxy.port) || proxy.host.isEmpty {
        reasons.append("\(tag) invalid proxy")
      }
      for rule in host.forwards {
        let targetOK = rule.kind == .dynamic || (1...65535).contains(rule.target.port)
        if !(0...65535).contains(rule.bind.port) || !targetOK {
          reasons.append("\(tag) invalid forward")
        }
      }
      // 保险库密钥：同一把不能引用两次；引用已删除的密钥是允许的（解析时跳过）。
      if let vaultKeyIDs = host.vaultKeyIDs,
        vaultKeyIDs.count > maximumVaultKeys || Set(vaultKeyIDs).count != vaultKeyIDs.count
      {
        reasons.append("\(tag) invalid vaultKeyIDs")
      }
      if let jump = host.jumpHostID, jump == host.id || !ids.contains(jump) {
        reasons.append("\(tag) invalid jumpHostID")
      }
      for value in [host.keepaliveInterval, host.keepaliveCountMax, host.connectTimeout]
      where (value ?? 0) < 0 {
        reasons.append("\(tag) negative timing")
      }
    }
    return reasons
  }

  // MARK: - 查询

  /// 与指定主机共用同一凭证 endpoint 的其它主机（删除口令前提示用；对应 tty7
  /// `profiles_sharing_endpoint`）。无法解析的主机不计入。
  public static func hostsSharingCredential(
    with id: UUID, in hosts: [SSHHostProfile]
  ) -> [SSHHostProfile] {
    guard let endpoint = try? SSHHostResolver.resolve(id, in: hosts).credentialEndpoint else {
      return []
    }
    return hosts.filter { other in
      other.id != id && !other.isDefaults
        && (try? SSHHostResolver.resolve(other.id, in: hosts).credentialEndpoint) == endpoint
    }
  }

  /// 引用了指定主机作为跳板的其它主机（删除前提示用）。
  public static func hostsUsingJump(_ id: UUID, in hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    hosts.filter { $0.jumpHostID == id }
  }
}

/// 私有文件的原子写入：目录 0700、文件 0600，同目录临时文件再 rename。
///
/// 临时文件必须与目标同目录：跨文件系统的 rename 会退化成复制，失去原子性。
public enum PrivateFileWriter {
  public static func write(_ data: Data, to fileURL: URL, fileManager: FileManager = .default) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let temporary = directory.appendingPathComponent(
      ".\(fileURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary, options: [.atomic])
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: fileURL)
      }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }
}
