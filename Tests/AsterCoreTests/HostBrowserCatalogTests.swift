import Foundation
import Testing

@testable import AsterCore

// HostBrowserCatalog：主机页的分组、搜索、标签筛选、排序、回车意图与副标题规则。

/// 固定的一组主机：两个命名分组、一个导入组、两台未分组主机和默认项。
private struct Fixture {
  let web = SSHHostProfile(name: "web", group: "prod", host: "10.0.0.1", user: "root", tags: ["nginx"])
  let db = SSHHostProfile(name: "db", group: "prod", host: "10.0.0.2", user: "postgres")
  let ci = SSHHostProfile(name: "ci", group: "build", host: "ci.example.com", port: 2222, user: "")
  let orb = SSHHostProfile(
    name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1", port: 32222, user: "root")
  let lab = SSHHostProfile(name: "Lab", host: "lab.local", user: "mike", tags: ["Home", "nginx"])
  let attic = SSHHostProfile(name: "attic", host: "attic.local", user: "")

  var all: [SSHHostProfile] { [.emptyDefaults(), web, db, ci, orb, lab, attic] }
}

@Test("顶层不过滤：列出全部分组（导入组在前），主机区只放未分组主机")
func hostBrowserTopLevelListsGroupsAndUngroupedHosts() {
  let f = Fixture()
  let listing = HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery())
  #expect(listing.groups == [
    HostBrowserGroup(name: SSHHostProfile.importedGroup, hostCount: 1),
    HostBrowserGroup(name: "build", hostCount: 1),
    HostBrowserGroup(name: "prod", hostCount: 2),
  ])
  #expect(listing.hosts.map(\.name) == ["attic", "Lab"])
}

@Test("钻进分组只看这一组；默认项永远不出现")
func hostBrowserGroupDrillDown() {
  let f = Fixture()
  let listing = HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(group: "prod"))
  #expect(listing.groups.isEmpty)
  #expect(listing.hosts.map(\.name) == ["db", "web"])
  let filtered = HostBrowserCatalog.listing(
    hosts: f.all, query: HostBrowserQuery(search: "post", group: "prod"))
  #expect(filtered.hosts.map(\.name) == ["db"])
}

@Test("顶层搜索平铺所有分组里的匹配主机，分组只留名称命中的")
func hostBrowserSearchFlattensAcrossGroups() {
  let f = Fixture()
  let byAddress = HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: "10.0.0"))
  #expect(byAddress.groups.isEmpty)
  #expect(byAddress.hosts.map(\.name) == ["db", "web"])

  let byGroup = HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: "PROD"))
  #expect(byGroup.groups == [HostBrowserGroup(name: "prod", hostCount: 2)])
  #expect(byGroup.hosts.map(\.name) == ["db", "web"])

  // 多个词都要命中；标签按 `#tag` 命中；连接串里的端口也能搜到。
  #expect(HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: "root 10.0"))
    .hosts.map(\.name) == ["web"])
  #expect(HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: "#home"))
    .hosts.map(\.name) == ["Lab"])
  #expect(HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: ":2222"))
    .hosts.map(\.name) == ["ci"])
  #expect(HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: "nothing"))
    == HostBrowserListing(groups: [], hosts: []))
}

@Test("标签筛选不分大小写，并与搜索叠加")
func hostBrowserTagFilter() {
  let f = Fixture()
  let tagged = HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(tag: "NGINX"))
  #expect(tagged.groups.isEmpty)
  #expect(tagged.hosts.map(\.name) == ["Lab", "web"])
  let both = HostBrowserCatalog.listing(hosts: f.all, query: HostBrowserQuery(search: "lab", tag: "nginx"))
  #expect(both.hosts.map(\.name) == ["Lab"])
  #expect(HostBrowserCatalog.tags(in: f.all) == ["Home", "nginx"])
}

@Test("最近使用排序：用过的按时间倒序在前，没用过的按名称排在后面")
func hostBrowserRecentSort() {
  let f = Fixture()
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  let lastUsed = [f.web.id: now.addingTimeInterval(-3_600), f.db.id: now.addingTimeInterval(-60)]
  let listing = HostBrowserCatalog.listing(
    hosts: f.all, query: HostBrowserQuery(group: "prod", sort: .recent), lastUsed: lastUsed)
  #expect(listing.hosts.map(\.name) == ["db", "web"])
  let mixed = HostBrowserCatalog.listing(
    hosts: f.all, query: HostBrowserQuery(search: "o", sort: .recent), lastUsed: [f.web.id: now])
  #expect(mixed.hosts.first?.name == "web")
  #expect(Array(mixed.hosts.dropFirst()).map(\.name) == ["attic", "ci", "db", "Lab", "orb"])
}

@Test("回车意图：同名主机优先，其次地址临时连接，最后是唯一可见主机")
func hostBrowserConnectIntent() {
  let f = Fixture()
  #expect(HostBrowserCatalog.connectIntent(query: "  ", hosts: f.all, visible: [f.web]) == nil)
  #expect(HostBrowserCatalog.connectIntent(query: "WEB", hosts: f.all, visible: []) == .host(f.web.id))
  #expect(HostBrowserCatalog.connectIntent(query: "root@10.0.0.1", hosts: f.all, visible: []) == .host(f.web.id))
  #expect(
    HostBrowserCatalog.connectIntent(query: "admin@192.168.1.9:2200", hosts: f.all, visible: [])
      == .target(QuickConnectTarget(user: "admin", host: "192.168.1.9", port: 2200)))
  #expect(HostBrowserCatalog.connectIntent(query: "postg", hosts: f.all, visible: [f.db]) == .host(f.db.id))
  #expect(HostBrowserCatalog.connectIntent(query: "o", hosts: f.all, visible: [f.db, f.web]) == nil)
  // 以 `-` 开头的「地址」会被 ssh 当成选项，不能变成临时连接。
  #expect(HostBrowserCatalog.connectIntent(query: "-oProxy@x.y", hosts: f.all, visible: []) == nil)
}

@Test("副标题：ssh + 用户名（空则用缺省用户），带标签时追加 #标签")
func hostBrowserSubtitle() {
  let f = Fixture()
  #expect(HostBrowserCatalog.subtitle(for: f.db, defaultUser: "me") == "ssh, postgres")
  #expect(HostBrowserCatalog.subtitle(for: f.attic, defaultUser: "me") == "ssh, me")
  #expect(HostBrowserCatalog.subtitle(for: f.attic, defaultUser: "") == "ssh")
  #expect(HostBrowserCatalog.subtitle(for: f.lab, defaultUser: "me") == "ssh, mike  #Home #nginx")
  #expect(HostBrowserCatalog.title(for: SSHHostProfile(name: "", host: "h", user: "u")) == "u@h")
}

@Test("复制主机：新 ID、新名称，导入组的副本放到未分组，其余字段不变")
func hostProfileDuplicatedKeepsSettings() throws {
  let f = Fixture()
  let copy = f.orb.duplicated(name: "orb 副本")
  #expect(copy.id != f.orb.id)
  #expect(copy.name == "orb 副本")
  #expect(copy.group == nil)
  #expect(copy.host == f.orb.host && copy.port == f.orb.port && copy.user == f.orb.user)
  let fixedID = UUID()
  var expected = f.web
  expected.name = "web 副本"
  let webCopy = f.web.duplicated(name: "web 副本", id: fixedID)
  #expect(webCopy.group == "prod")
  #expect(webCopy.tags == ["nginx"])
  // 除 ID 外与改名后的原主机完全相同，说明没有漏拷字段。
  #expect(try SSHHostProfile.encodedWithoutID(webCopy) == SSHHostProfile.encodedWithoutID(expected))
}

@Test("账本按 ID 给出最后使用时间，文本键不计入")
func hostUsageLastUsedByID() {
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  let id = UUID()
  var ledger = HostUsageLedger()
  ledger.record(.id(id), at: now)
  ledger.record(.target("alias"), at: now)
  #expect(ledger.lastUsedByID == [id: now])
}

extension SSHHostProfile {
  /// 去掉 ID 后的 JSON，用于比较「除 ID 外全部字段相同」。
  fileprivate static func encodedWithoutID(_ profile: SSHHostProfile) throws -> [String: String] {
    let data = try JSONEncoder().encode(profile)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "id")
    return object.mapValues { String(describing: $0) }
  }
}
