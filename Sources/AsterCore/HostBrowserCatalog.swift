import Foundation

// 侧栏「主机」页的纯目录计算：搜索、分组钻取、标签筛选、排序与搜索框回车意图。
// 不读文件、不碰 UI；App 层把 `SSHHostDirectory` 的主机列表与使用账本的快照传进来。

/// 主机页的排序方式。
public enum HostBrowserSort: String, CaseIterable, Sendable {
  /// 按名称 A–Z。
  case name
  /// 最近使用在前；从没用过的按名称排在后面。
  case recent
}

/// 主机页当前的筛选条件。
public struct HostBrowserQuery: Equatable, Sendable {
  /// 搜索框文本；按空白拆成多个词，每个词都要命中。
  public var search: String
  /// 钻取进的分组；nil 表示顶层。
  public var group: String?
  /// 只看带这个标签的主机（不分大小写）；nil 表示全部。
  public var tag: String?
  public var sort: HostBrowserSort

  public init(search: String = "", group: String? = nil, tag: String? = nil, sort: HostBrowserSort = .name) {
    self.search = search
    self.group = group
    self.tag = tag
    self.sort = sort
  }

  /// 是否在过滤（搜索或标签）。过滤时顶层把各分组里的匹配主机平铺出来。
  public var isFiltering: Bool {
    !search.trimmingCharacters(in: .whitespaces).isEmpty || tag != nil
  }
}

/// 一张分组卡片的数据。
public struct HostBrowserGroup: Equatable, Sendable {
  public var name: String
  public var hostCount: Int

  public init(name: String, hostCount: Int) {
    self.name = name
    self.hostCount = hostCount
  }
}

/// 一次计算的结果：分组卡片与主机卡片，都已排好序。
public struct HostBrowserListing: Equatable, Sendable {
  public var groups: [HostBrowserGroup]
  public var hosts: [SSHHostProfile]

  public init(groups: [HostBrowserGroup], hosts: [SSHHostProfile]) {
    self.groups = groups
    self.hosts = hosts
  }
}

/// 搜索框回车或「连接」按钮的意图。
public enum HostBrowserConnectIntent: Equatable, Sendable {
  /// 连接一台已保存主机（沿用它的认证与跳板配置）。
  case host(UUID)
  /// 临时连接 `user@host:port`，不保存。
  case target(QuickConnectTarget)
}

/// 主机页目录规则。
public enum HostBrowserCatalog {
  /// 按条件生成分组卡片与主机卡片。
  ///
  /// 顶层不过滤时：列出全部分组，主机区只放未分组的主机（分组里的主机点进分组再看）。
  /// 顶层过滤时：分组只留名称命中搜索词的，主机区平铺所有分组里的匹配主机——用户搜索时
  /// 想找的是主机本身，不该再让他猜在哪个分组里。钻进分组后只看这一组。
  ///
  /// - Parameters:
  ///   - hosts: 全部主机（可含默认项，会被排除）。
  ///   - groups: 明确声明的分组（可能还没有主机），与主机推出的分组合并后成卡片。
  ///   - lastUsed: 每台主机最后一次使用时间，供「最近使用」排序。
  public static func listing(
    hosts: [SSHHostProfile], groups: [String] = [], query: HostBrowserQuery, lastUsed: [UUID: Date] = [:]
  ) -> HostBrowserListing {
    let saved = hosts.filter { !$0.isDefaults }
    let tagged = saved.filter { host in
      guard let tag = query.tag else { return true }
      return (host.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
    let matched = tagged.filter { matches($0, search: query.search) }

    if let group = query.group {
      return HostBrowserListing(
        groups: [], hosts: sorted(matched.filter { $0.group == group }, by: query.sort, lastUsed: lastUsed))
    }
    if query.isFiltering {
      let terms = searchTerms(query.search)
      let groups = groupCards(tagged, declared: groups).filter { group in
        !terms.isEmpty && terms.allSatisfy { contains(group.name, $0) }
      }
      return HostBrowserListing(groups: groups, hosts: sorted(matched, by: query.sort, lastUsed: lastUsed))
    }
    return HostBrowserListing(
      groups: groupCards(saved, declared: groups),
      hosts: sorted(saved.filter { $0.group == nil }, by: query.sort, lastUsed: lastUsed))
  }

  /// 已保存主机里出现过的标签：不分大小写去重（保留第一次出现的写法），按名称排序。
  public static func tags(in hosts: [SSHHostProfile]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for tag in hosts.filter({ !$0.isDefaults }).flatMap({ $0.tags ?? [] })
    where seen.insert(tag.lowercased()).inserted {
      result.append(tag)
    }
    return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// 卡片标题：名称，名称为空时退回连接串。
  public static func title(for host: SSHHostProfile) -> String {
    host.name.isEmpty ? host.connectString : host.name
  }

  /// 卡片副标题：`ssh, <用户名>`，有标签时追加 `#标签`。
  ///
  /// - Parameter defaultUser: 主机没写用户名时实际会用的用户名（默认项或本机用户）；
  ///   空串表示不显示用户名。
  public static func subtitle(for host: SSHHostProfile, defaultUser: String) -> String {
    let user = host.user.isEmpty ? defaultUser : host.user
    var text = user.isEmpty ? "ssh" : "ssh, \(user)"
    let tags = host.tags ?? []
    if !tags.isEmpty { text += "  " + tags.map { "#\($0)" }.joined(separator: " ") }
    return text
  }

  /// 主机是否命中搜索词：每个词都要出现在名称、地址、用户名、连接串、分组或标签里。
  public static func matches(_ host: SSHHostProfile, search: String) -> Bool {
    let terms = searchTerms(search)
    guard !terms.isEmpty else { return true }
    let fields = [host.name, host.host, host.user, host.connectString, host.group ?? ""]
      + (host.tags ?? []).map { "#\($0)" }
    return terms.allSatisfy { term in fields.contains { contains($0, term) } }
  }

  /// 搜索框回车 / 「连接」按钮该做什么。
  ///
  /// 优先级：名称或连接串与输入完全相同的已保存主机（用它的认证配置，比临时连接更可能成功）
  /// → 像地址的输入按临时目标连接 → 过滤后只剩一台主机时连它 → 都不是返回 nil。
  ///
  /// - Parameter visible: 当前过滤后显示的主机，用于「只剩一台」的判断。
  public static func connectIntent(
    query: String, hosts: [SSHHostProfile], visible: [SSHHostProfile]
  ) -> HostBrowserConnectIntent? {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    let saved = hosts.filter { !$0.isDefaults }
    let byName = saved.filter { $0.name.caseInsensitiveCompare(text) == .orderedSame }
    if byName.count == 1 { return .host(byName[0].id) }
    let byAddress = saved.filter { $0.connectString == text }
    if byAddress.count == 1 { return .host(byAddress[0].id) }
    if QuickConnectTarget.looksLikeTarget(text), let target = QuickConnectTarget.parse(text) {
      return .target(target)
    }
    if visible.count == 1 { return .host(visible[0].id) }
    return nil
  }

  // MARK: - 内部

  /// 分组卡片：`~/.ssh/config` 导入组在前，其余按名称；只统计已保存主机。
  /// 声明过但没有主机的分组也出一张卡片，数量为 0。
  private static func groupCards(_ hosts: [SSHHostProfile], declared: [String]) -> [HostBrowserGroup] {
    var counts: [String: Int] = [:]
    for group in declared { counts[group] = 0 }
    for host in hosts { if let group = host.group { counts[group, default: 0] += 1 } }
    return counts.keys.sorted { lhs, rhs in
      let left = lhs == SSHHostProfile.importedGroup
      let right = rhs == SSHHostProfile.importedGroup
      if left != right { return left }
      return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
    .map { HostBrowserGroup(name: $0, hostCount: counts[$0] ?? 0) }
  }

  /// 按排序方式排主机；同名时按 ID 保证顺序稳定，避免每次刷新卡片跳动。
  private static func sorted(
    _ hosts: [SSHHostProfile], by sort: HostBrowserSort, lastUsed: [UUID: Date]
  ) -> [SSHHostProfile] {
    hosts.sorted { lhs, rhs in
      if sort == .recent {
        switch (lastUsed[lhs.id], lastUsed[rhs.id]) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
      }
      let order = title(for: lhs).localizedStandardCompare(title(for: rhs))
      return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
    }
  }

  /// 搜索词：按空白拆分，去掉空串。
  private static func searchTerms(_ search: String) -> [String] {
    search.split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// 不分大小写与变音符号的包含判断。
  private static func contains(_ field: String, _ term: String) -> Bool {
    field.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}
