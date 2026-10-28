// `tools-state.json` 的模型：启用状态、授权记录、开发目录与使用记录。授权只存在这里，不进 settings.json。
// 解码一律容错：坏字段取默认值、坏记录逐条丢弃、不认识的权限丢弃（下次运行时会重新请求授权），
// 一处手改错误或新旧版本差异不会让用户丢掉全部授权与使用记录。
import Foundation

/// 工具中心的持久化状态。
public struct ToolStateFile: Codable, Equatable, Sendable {
  public static let fileName = "tools-state.json"
  public static let currentVersion = 1

  public var version: Int
  /// 按插件 id 记录。
  public var plugins: [String: ToolPluginState]
  /// 登记的开发目录（绝对路径），按登记顺序、不重复。
  public var developmentFolders: [String]
  public var usage: ToolUsageStats

  /// 逐字段构造，缺省为空状态。
  public init(
    version: Int = ToolStateFile.currentVersion,
    plugins: [String: ToolPluginState] = [:],
    developmentFolders: [String] = [],
    usage: ToolUsageStats = ToolUsageStats()
  ) {
    self.version = version
    self.plugins = plugins
    self.developmentFolders = developmentFolders
    self.usage = usage
  }

  private enum CodingKeys: String, CodingKey {
    case version, plugins, developmentFolders, usage
  }

  /// 缺字段或字段类型不对时按默认值补齐，坏的插件记录与开发目录逐条丢弃。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = values.lossyDecode(Int.self, forKey: .version) ?? Self.currentVersion
    plugins =
      values.lossyDecode([String: ToolLossy<ToolPluginState>].self, forKey: .plugins)?
      .compactMapValues(\.value) ?? [:]
    let folders = values.lossyDecode([ToolLossy<String>].self, forKey: .developmentFolders) ?? []
    var seen = Set<String>()
    developmentFolders = folders.compactMap(\.value).filter { !$0.isEmpty && seen.insert($0).inserted }
    usage = values.lossyDecode(ToolUsageStats.self, forKey: .usage) ?? ToolUsageStats()
  }
}

/// 单个插件的用户决定。
public struct ToolPluginState: Codable, Equatable, Sendable {
  public var enabled: Bool
  /// 用户同意过的权限。
  public var grantedPermissions: [ToolPermission]
  /// 用户同意过的域名。
  public var grantedNetworkDomains: [String]
  /// 同意时的文件摘要（用户来源才比对）。
  public var approvedDigest: String?
  /// 同意时的版本，仅用于展示。
  public var approvedVersion: String?
  /// 视图 id → 用户对该视图的设置（启用、改放的位置）。没有记录的视图按清单缺省。
  public var views: [String: ToolViewState]

  /// 逐字段构造；缺省为启用且没有任何授权。
  public init(
    enabled: Bool = true,
    grantedPermissions: [ToolPermission] = [],
    grantedNetworkDomains: [String] = [],
    approvedDigest: String? = nil,
    approvedVersion: String? = nil,
    views: [String: ToolViewState] = [:]
  ) {
    self.enabled = enabled
    self.grantedPermissions = grantedPermissions
    self.grantedNetworkDomains = grantedNetworkDomains
    self.approvedDigest = approvedDigest
    self.approvedVersion = approvedVersion
    self.views = views
  }

  /// 是否经过用户确认。只切换过启用开关的记录不算，信任判断据此区分「第一次运行」与「新增了权限」。
  public var hasApproval: Bool {
    approvedVersion != nil || approvedDigest != nil || !grantedPermissions.isEmpty || !grantedNetworkDomains.isEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, grantedPermissions, grantedNetworkDomains, approvedDigest, approvedVersion, views
  }

  /// 缺 `enabled` 视为启用；不认识的权限丢弃，宁可让插件重新请求授权，也不让整条记录失效。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = values.lossyDecode(Bool.self, forKey: .enabled) ?? true
    let permissions = values.lossyDecode([ToolLossy<String>].self, forKey: .grantedPermissions) ?? []
    var seen = Set<ToolPermission>()
    grantedPermissions = permissions.compactMap { $0.value.flatMap(ToolPermission.init(rawValue:)) }
      .filter { seen.insert($0).inserted }
    grantedNetworkDomains =
      (values.lossyDecode([ToolLossy<String>].self, forKey: .grantedNetworkDomains) ?? []).compactMap(\.value)
    approvedDigest = values.lossyDecode(String.self, forKey: .approvedDigest)
    approvedVersion = values.lossyDecode(String.self, forKey: .approvedVersion)
    views =
      values.lossyDecode([String: ToolLossy<ToolViewState>].self, forKey: .views)?.compactMapValues(\.value) ?? [:]
  }

  /// 只有缺省值、没有任何用户决定（授权或视图设置）。
  public var isPristine: Bool {
    !hasApproval && views.isEmpty
  }
}

/// 用户对单个视图的设置。
public struct ToolViewState: Codable, Equatable, Sendable {
  public var enabled: Bool
  /// 用户改放的位置；nil 表示用清单缺省。
  public var slot: ToolViewSlot?

  public init(enabled: Bool = true, slot: ToolViewSlot? = nil) {
    self.enabled = enabled
    self.slot = slot
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, slot
  }

  /// 缺 `enabled` 视为启用；不认识的位置（例如新版本写入的挂载点）按没改过处理。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = values.lossyDecode(Bool.self, forKey: .enabled) ?? true
    slot = values.lossyDecode(String.self, forKey: .slot).flatMap(ToolViewSlot.init(rawValue:))
  }

  /// 与缺省相同（启用、没改位置），可以不存。
  public var isDefault: Bool { enabled && slot == nil }
}

/// 功能使用记录，用于排序。
public struct ToolUsageStats: Codable, Equatable, Sendable {
  /// 最多保留的记录数，超出时丢掉最久没用的。
  public static let maximumRecords = 500
  /// frecency 的半衰期（天）。
  public static let halfLifeDays = 7.0
  public var records: [String: ToolUsageRecord]

  /// 用已有记录构造。
  public init(records: [String: ToolUsageRecord] = [:]) {
    self.records = records
  }

  private enum CodingKeys: String, CodingKey {
    case records
  }

  /// 坏记录与次数不为正的记录逐条丢弃；手改后超过上限的部分按最久没用的裁掉。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let decoded = values.lossyDecode([String: ToolLossy<ToolUsageRecord>].self, forKey: .records) ?? [:]
    records = decoded.compactMapValues(\.value).filter { $0.value.count > 0 }
    prune(keeping: nil)
  }

  /// 记一次使用。超过上限时丢掉最久没用的记录，但不会丢掉刚记的这一条（即使时钟回拨让它显得最旧）。
  public mutating func recordUse(_ entryID: String, at date: Date) {
    var record = records[entryID] ?? ToolUsageRecord(count: 0, lastUsed: date)
    record.count = record.count < Int.max ? record.count + 1 : record.count
    record.lastUsed = date
    records[entryID] = record
    prune(keeping: entryID)
  }

  /// 删除某个插件全部功能的记录（卸载插件时用）。
  public mutating func removeRecords(forPluginID pluginID: String) {
    records = records.filter { ToolCatalogEntry.splitID($0.key)?.pluginID != pluginID }
  }

  /// 频次 × 新近程度：次数按 7 天半衰期衰减；从没用过为 0，未来时间按现在算。
  public func frecency(_ entryID: String, now: Date) -> Double {
    guard let record = records[entryID], record.count > 0 else { return 0 }
    let ageDays = max(0, now.timeIntervalSince(record.lastUsed) / 86_400)
    return Double(record.count) * pow(0.5, ageDays / Self.halfLifeDays)
  }

  /// 超过上限时按「最近使用时间、再按 id」从旧到新淘汰，结果与字典遍历顺序无关。
  private mutating func prune(keeping protected: String?) {
    let excess = records.count - Self.maximumRecords
    guard excess > 0 else { return }
    let victims = records
      .filter { $0.key != protected }
      .sorted { ($0.value.lastUsed, $0.key) < ($1.value.lastUsed, $1.key) }
      .prefix(excess)
    for victim in victims { records.removeValue(forKey: victim.key) }
  }
}

/// 单个功能的使用次数与最近时间。
public struct ToolUsageRecord: Codable, Equatable, Sendable {
  public var count: Int
  public var lastUsed: Date

  /// 逐字段构造。
  public init(count: Int, lastUsed: Date) {
    self.count = count
    self.lastUsed = lastUsed
  }

  private enum CodingKeys: String, CodingKey {
    case count, lastUsed
  }

  /// `lastUsed` 读 Unix 秒数；也接受 ISO 8601 字符串（手改文件时常见）。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    count = try values.decode(Int.self, forKey: .count)
    if let seconds = values.lossyDecode(Double.self, forKey: .lastUsed) {
      lastUsed = Date(timeIntervalSince1970: seconds)
    } else {
      let text = try values.decode(String.self, forKey: .lastUsed)
      do {
        lastUsed = try Date(text, strategy: .iso8601)
      } catch {
        throw DecodingError.dataCorruptedError(forKey: .lastUsed, in: values, debugDescription: "not a date: \(text)")
      }
    }
  }

  /// `lastUsed` 固定写成 Unix 秒数，不受调用方 JSONEncoder 日期策略影响，读写两侧因此总是一致。
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(count, forKey: .count)
    try values.encode(lastUsed.timeIntervalSince1970, forKey: .lastUsed)
  }
}

// MARK: - 容错解码

/// 解码失败时为 nil 的包装，用来在数组与字典里逐条跳过坏记录。
struct ToolLossy<Value: Decodable>: Decodable {
  let value: Value?

  /// 失败即视为这条记录不存在：状态文件的约定是丢弃坏记录而不是让整份文件失败，这里不需要上报错误。
  init(from decoder: any Decoder) throws {
    do {
      value = try decoder.singleValueContainer().decode(Value.self)
    } catch {
      value = nil
    }
  }
}

extension KeyedDecodingContainer {
  /// 容错取值：字段缺失、为 null 或类型不对时返回 nil，由调用方换成默认值。
  func lossyDecode<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
    do {
      return try decodeIfPresent(type, forKey: key)
    } catch {
      return nil
    }
  }
}
