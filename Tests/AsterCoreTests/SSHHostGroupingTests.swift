import Foundation
import Testing

@testable import AsterCore

// SSHHostGrouping：新建、重命名、删除分组的纯规则，以及快照里声明分组的存储往返。

/// 两台在 prod 组、一台在导入组、一台未分组，外加一个声明的空分组 staging。
private func groupingFixture() -> SSHHostSnapshot {
  SSHHostSnapshot(
    hosts: [
      .emptyDefaults(),
      SSHHostProfile(name: "web", group: "prod", host: "10.0.0.1"),
      SSHHostProfile(name: "db", group: "prod", host: "10.0.0.2"),
      SSHHostProfile(name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1"),
      SSHHostProfile(name: "lab", host: "lab.local"),
    ],
    groups: ["staging"])
}

@Test("existingGroups 合并主机推出的分组与声明的空分组")
func hostGroupingExistingGroupsUnionsDeclared() {
  #expect(SSHHostGrouping.existingGroups(in: groupingFixture()) == ["prod", SSHHostProfile.importedGroup, "staging"])
}

@Test("新建分组：去空白后追加到声明列表；空名、重名、导入组名都拒绝")
func hostGroupingCreate() throws {
  let base = groupingFixture()
  let created = try SSHHostGrouping.create("  dev ", in: base)
  #expect(created.groups == ["staging", "dev"])
  #expect(created.hosts == base.hosts)
  #expect(throws: SSHHostGroupingError.emptyName) { try SSHHostGrouping.create("   ", in: base) }
  #expect(throws: SSHHostGroupingError.alreadyExists("prod")) { try SSHHostGrouping.create("prod", in: base) }
  #expect(throws: SSHHostGroupingError.alreadyExists("staging")) { try SSHHostGrouping.create("staging", in: base) }
  #expect(throws: SSHHostGroupingError.reserved) {
    try SSHHostGrouping.create(SSHHostProfile.importedGroup, in: base)
  }
  #expect(throws: SSHHostGroupingError.invalidName) { try SSHHostGrouping.create("a\nb", in: base) }
}

@Test("重命名分组：组内主机一起改，改过名的分组进入声明列表；导入组、未知组、重名都拒绝")
func hostGroupingRename() throws {
  let base = groupingFixture()
  let renamed = try SSHHostGrouping.rename("prod", to: "production", in: base)
  #expect(renamed.hosts.filter { $0.group == "production" }.map(\.name) == ["web", "db"])
  #expect(!renamed.hosts.contains { $0.group == "prod" })
  #expect(renamed.groups == ["staging", "production"])
  // 声明的空分组改名：只换声明列表里的名字。
  let declared = try SSHHostGrouping.rename("staging", to: "qa", in: base)
  #expect(declared.groups == ["qa"])
  // 新旧同名原样返回。
  #expect(try SSHHostGrouping.rename("prod", to: "prod", in: base) == base)
  #expect(throws: SSHHostGroupingError.reserved) {
    try SSHHostGrouping.rename(SSHHostProfile.importedGroup, to: "x", in: base)
  }
  #expect(throws: SSHHostGroupingError.reserved) {
    try SSHHostGrouping.rename("prod", to: SSHHostProfile.importedGroup, in: base)
  }
  #expect(throws: SSHHostGroupingError.unknownGroup) { try SSHHostGrouping.rename("nope", to: "x", in: base) }
  #expect(throws: SSHHostGroupingError.alreadyExists("staging")) {
    try SSHHostGrouping.rename("prod", to: "staging", in: base)
  }
}

@Test("删除分组：组内主机变未分组并保留，声明列表去掉它；导入组不能删")
func hostGroupingDelete() throws {
  let base = groupingFixture()
  let deleted = try SSHHostGrouping.delete("prod", in: base)
  #expect(deleted.hosts.count == base.hosts.count)
  #expect(deleted.hosts.filter { $0.group == nil && !$0.isDefaults }.map(\.name) == ["web", "db", "lab"])
  #expect(try SSHHostGrouping.delete("staging", in: base).groups.isEmpty)
  #expect(throws: SSHHostGroupingError.reserved) {
    try SSHHostGrouping.delete(SSHHostProfile.importedGroup, in: base)
  }
  #expect(throws: SSHHostGroupingError.unknownGroup) { try SSHHostGrouping.delete("nope", in: base) }
}

@Test("存储：声明的分组随 hosts.json 往返；只存主机时沿用当前分组；空分组不写 groups 键")
func hostStoreRoundTripsDeclaredGroups() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aster-ssh-groups-\(UUID().uuidString)").appendingPathComponent("hosts.json")
  let store = SSHHostStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  let host = SSHHostProfile(name: "Box", host: "10.0.0.1")
  try store.save(SSHHostSnapshot(hosts: [host], groups: [" dev ", "dev", "", SSHHostProfile.importedGroup, "qa"]))
  #expect(store.effectiveGroups == ["dev", "qa"])
  try store.load()
  #expect(store.effectiveGroups == ["dev", "qa"])
  #expect(try SSHHostStore.decodeSnapshot(Data(contentsOf: url)).groups == ["dev", "qa"])

  // 只存主机：分组不丢。
  try store.save([host, SSHHostProfile(name: "Two", host: "10.0.0.2")])
  #expect(store.effectiveGroups == ["dev", "qa"])
  #expect(store.effectiveHosts.count == 3)

  // 分组清空后文件里没有 groups 键，和旧版本格式一致。
  try store.save(SSHHostSnapshot(hosts: [host]))
  #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"groups\""))

  // 非法分组名整份拒绝，不落盘。
  #expect(throws: SSHHostStoreError.self) {
    try store.save(SSHHostSnapshot(hosts: [host], groups: [String(repeating: "x", count: 65)]))
  }
  #expect(store.effectiveGroups.isEmpty)
}

@Test("目录清单：声明的空分组也出卡片（0 台），搜索按名称命中；钻进空分组没有主机")
func hostBrowserListsDeclaredEmptyGroups() {
  let snapshot = groupingFixture()
  let top = HostBrowserCatalog.listing(hosts: snapshot.hosts, groups: snapshot.groups, query: HostBrowserQuery())
  #expect(top.groups == [
    HostBrowserGroup(name: SSHHostProfile.importedGroup, hostCount: 1),
    HostBrowserGroup(name: "prod", hostCount: 2),
    HostBrowserGroup(name: "staging", hostCount: 0),
  ])
  let searched = HostBrowserCatalog.listing(
    hosts: snapshot.hosts, groups: snapshot.groups, query: HostBrowserQuery(search: "stag"))
  #expect(searched.groups.map(\.name) == ["staging"])
  let inside = HostBrowserCatalog.listing(
    hosts: snapshot.hosts, groups: snapshot.groups, query: HostBrowserQuery(group: "staging"))
  #expect(inside.groups.isEmpty && inside.hosts.isEmpty)
}
