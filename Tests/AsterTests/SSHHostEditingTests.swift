// 抽出的主机编辑规则：保存（清理 → 校验 → 落盘）、编辑期间被删的主机、跳板成环、删除影响与忘记口令。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 临时 hosts.json 上的主机目录。
@MainActor
private func makeEditingDirectory(_ hosts: [SSHHostProfile]) throws -> (SSHHostDirectory, URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterHostEditing-\(UUID().uuidString)", isDirectory: true)
  let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
  try store.save([.emptyDefaults()] + hosts)
  return (SSHHostDirectory(store: store), root)
}

@Test("保存：先清理再校验，失败不落盘；编辑期间被删的主机不会被保存加回来")
@MainActor
func hostEditingSaveRules() throws {
  let a = SSHHostProfile(name: "a", host: "a.example")
  let (directory, root) = try makeEditingDirectory([a])
  defer { try? FileManager.default.removeItem(at: root) }

  var edited = a
  edited.knownHostsFiles = []
  edited.identityAgent = "  "
  let saved = try SSHHostEditing.save(edited, in: directory, requireExisting: true)
  #expect(saved.knownHostsFiles == nil && saved.identityAgent == nil)
  #expect(directory.host(a.id) == saved)

  var bad = a
  bad.port = 0
  #expect(throws: SSHHostEditingError.invalidProfile([L("端口必须在 1–65535 之间")])) {
    try SSHHostEditing.save(bad, in: directory)
  }
  #expect(directory.host(a.id)?.port == nil)

  try directory.remove(a.id)
  #expect(throws: SSHHostEditingError.unknownHost) {
    try SSHHostEditing.save(saved, in: directory, requireExisting: true)
  }
  #expect(directory.host(a.id) == nil)
  // 新建（不要求已存在）照常写入；默认项总是允许保存。
  try SSHHostEditing.save(saved, in: directory)
  #expect(directory.host(a.id) != nil)
  var defaults = SSHHostProfile.emptyDefaults()
  defaults.connectTimeout = 5
  try SSHHostEditing.save(defaults, in: directory, requireExisting: true)
  #expect(directory.hosts.first(where: \.isDefaults)?.connectTimeout == 5)
}

@Test("保存：跳板两两互指成环时拒绝，并给出中文原因")
@MainActor
func hostEditingRejectsJumpCycle() throws {
  let a = SSHHostProfile(name: "a", host: "a")
  var b = SSHHostProfile(name: "b", host: "b")
  b.jumpHostID = a.id
  let (directory, root) = try makeEditingDirectory([a, b])
  defer { try? FileManager.default.removeItem(at: root) }
  var cyclic = a
  cyclic.jumpHostID = b.id
  #expect(throws: SSHHostEditingError.invalidProfile([L("跳板机形成了循环")])) {
    try SSHHostEditing.save(cyclic, in: directory)
  }
}

@Test("删除影响与忘记口令：列出引用的机器、跳板依赖与共用口令的主机；口令按 endpoint 删除")
@MainActor
func hostEditingDeletionImpactAndForgetPassword() throws {
  let a = SSHHostProfile(name: "a", host: "shared.example", user: "root")
  let twin = SSHHostProfile(name: "twin", host: "shared.example", user: "root")
  var child = SSHHostProfile(name: "child", host: "c.example")
  child.jumpHostID = a.id
  let (directory, root) = try makeEditingDirectory([a, twin, child])
  defer { try? FileManager.default.removeItem(at: root) }
  let machine = MachineProfile(label: "build-box", sshTarget: nil, hostID: a.id)
  let impact = SSHHostEditing.deletionImpact(of: a.id, hosts: directory.hosts, machines: [machine])
  #expect(impact == SSHHostDeletionImpact(machines: ["build-box"], jumpDependents: ["child"], credentialSharedWith: ["twin"]))

  let credentials = InMemoryVaultCredentials()
  try credentials.setPassword("pw", for: "root@shared.example:22")
  let passwords = HostsPageCredentialPasswords(credentials: credentials)
  try SSHHostEditing.forgetPassword(a.id, in: directory, passwords: passwords)
  #expect(!credentials.hasPassword(for: "root@shared.example:22"))
  #expect(throws: SSHHostEditingError.unknownHost) {
    try SSHHostEditing.forgetPassword(SSHHostProfile.defaultsProfileID, in: directory, passwords: passwords)
  }
}
