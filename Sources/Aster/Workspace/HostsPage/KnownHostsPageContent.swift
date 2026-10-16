// 「已知主机」子页要显示的内容：按文件分组、搜索过滤、覆盖主机的说明文字与删除选项。
// 纯数据推导，不碰视图，便于测试；数据来自 `SSHKnownHostsService` 的最近一次列表。
import AsterCore
import Foundation

/// 一条记录在页面上的样子。
struct KnownHostsPageRow: Equatable {
  let entry: SSHKnownHostsListing.Entry
  /// 覆盖的主机说明（明文模式 / （已哈希） + 匹配到的已保存主机名）。
  let title: String
  /// 删除确认里列出的主机。
  let covered: [String]
  let removable: Bool
}

/// 一个 known_hosts 文件分组。
struct KnownHostsPageSection: Equatable {
  let file: SSHKnownHostsListing.File
  /// 显示用路径（家目录写成 `~`）。
  let displayPath: String
  /// 该文件里的记录总数（不受搜索影响）。
  let total: Int
  let rows: [KnownHostsPageRow]
  /// 卡片里没有可显示的记录时的一行说明（读取失败、没有记录、没有匹配）。
  let placeholder: String?
  /// 无法解析而跳过的行号。
  let skippedLines: [Int]
}

/// 删除确认里的一个选项。
enum KnownHostsDeleteChoice: Equatable {
  /// 删除整行。
  case line
  /// 只删除这一行里命中该主机的模式。
  case host(SSHHostPort)
}

/// 从服务状态推导页面内容的纯函数集合。
enum KnownHostsPageContent {
  /// `host:port` 的显示文本：22 端口省略，其它端口写成 `[host]:port`（与 known_hosts 写法一致）。
  static func endpointText(_ endpoint: SSHHostPort) -> String {
    endpoint.port == 22 ? endpoint.host : "[\(endpoint.host)]:\(endpoint.port)"
  }

  /// 一条记录覆盖的主机说明：明文模式原样列出；hashed 记录只能靠匹配到的已保存主机写出名称。
  static func title(
    for entry: SSHKnownHostsListing.Entry, names: (SSHHostPort) -> [String]
  ) -> String {
    if entry.hashed {
      let plain = entry.hosts.filter { $0 != "(hashed)" }
      let text = ([L("（已哈希）")] + plain).joined(separator: ", ")
      // hashed 行看不出主机，命中项写成「名称（地址）」，没有名称的只写地址。
      let described = entry.matches.map { endpoint in
        let saved = names(endpoint)
        let address = endpointText(endpoint)
        return saved.isEmpty ? address : "\(saved.joined(separator: "、"))（\(address)）"
      }
      guard !described.isEmpty else { return text }
      return "\(text) — " + L("匹配：\(described.joined(separator: "、"))")
    }
    // 明文模式本身就写出了地址，只追加已保存主机名，不再重复地址。
    var saved: [String] = []
    for name in entry.matches.flatMap(names) where !saved.contains(name) { saved.append(name) }
    let hosts = entry.hosts.joined(separator: ", ")
    return saved.isEmpty ? hosts : "\(hosts) — \(saved.joined(separator: "、"))"
  }

  /// 删除确认里列出的主机：hashed 记录列命中主机；明文记录列模式本身（去掉取反模式）。
  static func covered(by entry: SSHKnownHostsListing.Entry) -> [String] {
    entry.hashed
      ? entry.matches.map(endpointText)
      : entry.hosts.filter { $0 != "(hashed)" && !$0.hasPrefix("!") }
  }

  /// 删除选项：先「删除整行」，多模式行再给每个命中主机一个「只删除」。
  /// 单模式行删掉唯一模式等于删整行，不再单列。
  static func deleteChoices(for entry: SSHKnownHostsListing.Entry) -> [KnownHostsDeleteChoice] {
    guard entry.hosts.count > 1 else { return [.line] }
    return [.line] + entry.matches.map { .host($0) }
  }

  /// 搜索按主机模式、命中主机与其名称、算法、指纹与注释过滤（不区分大小写）；空查询全部通过。
  static func matches(
    _ entry: SSHKnownHostsListing.Entry, query: String, names: (SSHHostPort) -> [String]
  ) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    let haystack =
      entry.hosts + entry.matches.flatMap(names) + entry.matches.map(endpointText)
      + [entry.algorithm, entry.fingerprint, entry.comment ?? ""]
    return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
  }

  /// 按文件分组；文件顺序与 aster-ssh 输出一致（默认文件在前，系统级在后）。
  static func sections(
    listing: SSHKnownHostsListing, query: String,
    names: (SSHHostPort) -> [String], isRemovable: (SSHKnownHostsListing.Entry) -> Bool
  ) -> [KnownHostsPageSection] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return listing.files.map { file in
      let own = listing.entries.filter { $0.file == file.path }
      let rows = own.filter { matches($0, query: trimmed, names: names) }.map { entry in
        KnownHostsPageRow(
          entry: entry, title: title(for: entry, names: names), covered: covered(by: entry),
          removable: isRemovable(entry))
      }
      let placeholder: String? =
        if let error = file.error { L("无法读取：\(error)") }
        // 不存在的文件已由标题徽章说明，卡片不再重复。
        else if !file.exists { nil }
        else if own.isEmpty { L("没有记录") }
        else if rows.isEmpty { L("没有匹配“\(trimmed)”的记录") }
        else { nil }
      return KnownHostsPageSection(
        file: file, displayPath: SSHKnownHostsService.displayPath(file.path), total: own.count,
        rows: rows, placeholder: placeholder,
        skippedLines: listing.skipped.filter { $0.file == file.path }.map(\.line))
    }
  }

  /// 文件分组的徽章：系统级 · 只读、文件不存在、不可写（存在但不能改）；系统级文件可能同时不存在。
  static func badges(for file: SSHKnownHostsListing.File) -> [String] {
    var badges: [String] = []
    if file.global { badges.append(L("系统级 · 只读")) }
    if !file.exists {
      badges.append(L("文件不存在"))
    } else if !file.global && !file.writable && file.error == nil {
      badges.append(L("不可写"))
    }
    return badges
  }
}
