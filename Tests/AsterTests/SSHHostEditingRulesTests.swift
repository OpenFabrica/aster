// 主机编辑规则的边界与派生数据：清理错误到用户文案的映射、字段随保存落盘、列表排序、
// 分组与标签候选、口令 endpoint 与错误文案。保存主流程见 SSHHostEditingTests.swift。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 临时 hosts.json 上的主机目录；返回目录与要清理的根目录。
@MainActor
private func makeRulesDirectory(_ hosts: [SSHHostProfile]) throws -> (SSHHostDirectory, URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterHostEditingRules-\(UUID().uuidString)", isDirectory: true)
  let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
  try store.save([.emptyDefaults()] + hosts)
  return (SSHHostDirectory(store: store), root)
}

@Test("保存边界：控制字符给出中文原因，超量条目按参数无效，标签含逗号被拒；失败都不落盘")
@MainActor
func hostEditingSaveRejectsUnsafeFields() throws {
  let host = SSHHostProfile(
    name: "vault", host: "10.0.0.9", user: "ops", identityAgent: "~/agent.sock", tags: ["prod", "web"])
  let (directory, root) = try makeRulesDirectory([host])
  defer { try? FileManager.default.removeItem(at: root) }
  let controlReason = SSHHostEditingError.invalidProfile([L("不能包含换行或控制字符")])

  var proxy = host
  proxy.proxyCommand = "nc %h %p\nrm -rf ~"
  #expect(throws: controlReason) { try SSHHostEditing.save(proxy, in: directory) }
  var agent = host
  agent.identityAgent = "/tmp/agent.sock\nProxyCommand evil"
  #expect(throws: controlReason) { try SSHHostEditing.save(agent, in: directory) }
  var controlTag = host
  controlTag.tags = ["a\u{7}"]
  #expect(throws: controlReason) { try SSHHostEditing.save(controlTag, in: directory) }
  var commaTag = host
  commaTag.tags = ["a,b"]
  #expect(throws: SSHHostEditingError.invalidProfile([L("标签过长或包含逗号/换行")])) {
    try SSHHostEditing.save(commaTag, in: directory)
  }
  var tooMany = host
  tooMany.identityFiles = Array(repeating: "~/.ssh/id", count: SSHHostEditRules.maximumIdentityFiles + 1)
  #expect(throws: SSHHostEditingError.invalidPayload) { try SSHHostEditing.save(tooMany, in: directory) }
  var unnamed = host
  unnamed.name = ""
  #expect(throws: SSHHostEditingError.invalidProfile([L("名称不能为空")])) {
    try SSHHostEditing.save(unnamed, in: directory)
  }
  #expect(directory.host(host.id) == host)
}

@Test("保存往返：只用指定私钥、known_hosts、Agent 套接字、标签与保险库密钥原样落盘；空值存成 nil")
@MainActor
func hostEditingSaveRoundTripsOptionalFields() throws {
  let (directory, root) = try makeRulesDirectory([])
  defer { try? FileManager.default.removeItem(at: root) }
  let host = SSHHostProfile(
    name: "orb", host: "127.0.0.1", port: 32222, user: "root",
    identityFiles: ["~/.orbstack/ssh/id_ed25519"], identitiesOnly: true,
    knownHostsFiles: ["~/.orbstack/ssh/known_hosts", "~/.ssh/known_hosts"],
    identityAgent: "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
    tags: ["prod", "web"], vaultKeyIDs: [UUID(), UUID()])
  try SSHHostEditing.save(host, in: directory)
  let reloaded = try SSHHostStore(fileURL: directory.store.fileURL).load()
  #expect(reloaded.first { $0.id == host.id } == host)

  var cleared = host
  cleared.knownHostsFiles = []
  cleared.identitiesOnly = false
  cleared.identityAgent = "   "
  cleared.tags = []
  cleared.vaultKeyIDs = []
  try SSHHostEditing.save(cleared, in: directory, requireExisting: true)
  let after = try #require(directory.host(host.id))
  #expect(after.knownHostsFiles == nil && after.identitiesOnly == false && after.identityAgent == nil)
  #expect(after.tags == nil && after.vaultKeyIDs == nil)
}

@Test("列表顺序：导入组在前、命名分组按名称、未分组最后；分组与标签候选去重并保持显示顺序")
@MainActor
func hostEditingSortsGroupsAndTags() {
  let imported = SSHHostProfile(name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1")
  let web = SSHHostProfile(name: "web", group: "prod", host: "web.example.com", tags: ["Prod", "db"])
  let api = SSHHostProfile(name: "api", group: "prod", host: "api.example.com", tags: ["prod", "web"])
  let alpha = SSHHostProfile(name: "alpha", group: "dev", host: "alpha.example.com")
  let loose = SSHHostProfile(name: "web-alt", host: "web.example.com")
  let sorted = SSHHostEditing.sorted([loose, web, api, alpha, imported])
  #expect(sorted.map(\.name) == ["orb", "alpha", "api", "web", "web-alt"])
  #expect(SSHHostEditing.orderedGroups(sorted) == [SSHHostProfile.importedGroup, "dev", "prod"])
  // 「prod」与「Prod」不分大小写合并，保留先出现的写法。
  #expect(SSHHostEditing.orderedTags(sorted) == ["prod", "web", "db"])
}

@Test("口令 endpoint：可解析主机按 user@host:port 计算，共用同一 endpoint；无法解析的主机没有 endpoint")
@MainActor
func hostEditingCredentialEndpoints() {
  let web = SSHHostProfile(name: "web", host: "web.example.com", user: "deploy")
  let webAlt = SSHHostProfile(name: "web-alt", group: "prod", host: "web.example.com", port: 22, user: "deploy")
  let other = SSHHostProfile(name: "other", host: "web.example.com", port: 2222, user: "deploy")
  var broken = SSHHostProfile(name: "broken", host: "b.example.com")
  broken.jumpHostID = UUID()
  let endpoints = SSHHostEditing.credentialEndpoints([.emptyDefaults(), web, webAlt, other, broken])
  #expect(endpoints[web.id] == "deploy@web.example.com:22")
  #expect(endpoints[webAlt.id] == endpoints[web.id])
  #expect(endpoints[other.id] == "deploy@web.example.com:2222")
  #expect(endpoints[broken.id] == nil)
}

@Test("错误文案：找不到 aster-ssh、存储校验原因与编辑错误都转成一句中文")
@MainActor
func hostEditingDescribesErrors() {
  #expect(SSHHostEditing.describe(SSHBrokerError.executableMissing) == L("找不到 aster-ssh，请重新构建 Aster.app"))
  #expect(SSHHostEditing.describe(SSHHostEditingError.unknownHost) == L("主机不存在，可能已被删除"))
  #expect(
    SSHHostEditing.describe(SSHHostStoreError.invalidHosts(reasons: ["[1] invalid port"]))
      == L("主机配置无效：\(L("端口必须在 1–65535 之间"))"))
  #expect(SSHHostEditing.friendlyReason("[2] empty name") == L("名称不能为空"))
  #expect(SSHHostEditing.friendlyReason("something new") == "something new")
}
