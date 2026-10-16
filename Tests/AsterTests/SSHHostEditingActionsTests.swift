// 主机行动作的共用服务：删除时的口令清理（`SSHHostRemoval`）、复制、从 `~/.ssh/config` 合并导入，
// 以及新建 `~/.ssh/config` 的权限。全部用临时目录与记录调用的假钥匙串。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 假口令钥匙串：记录已保存的 endpoint 与删除调用。
@MainActor
private final class RecordingHostPasswords: SSHHostPasswordStore {
  var saved: Set<String> = []
  var deleted: [String] = []

  /// 是否已保存该 endpoint 的口令。
  func hasPassword(for endpoint: String) -> Bool { saved.contains(endpoint) }

  /// 记录删除并移除口令。
  func deletePassword(for endpoint: String) throws {
    deleted.append(endpoint)
    saved.remove(endpoint)
  }
}

/// 临时 hosts.json 上的主机目录；返回目录与要清理的根目录。
@MainActor
private func makeActionsDirectory(_ hosts: [SSHHostProfile]) throws -> (SSHHostDirectory, URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterHostEditingActions-\(UUID().uuidString)", isDirectory: true)
  let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
  try store.save([.emptyDefaults()] + hosts)
  return (SSHHostDirectory(store: store), root)
}

@Test("删除主机清掉跳板引用；口令只在没有其它主机共用时才一起删除；默认项不能删")
@MainActor
func hostRemovalHonorsSharedCredentials() throws {
  let web = SSHHostProfile(name: "web", host: "web.example.com", user: "deploy")
  let webAlt = SSHHostProfile(name: "web-alt", group: "prod", host: "web.example.com", user: "deploy")
  let api = SSHHostProfile(name: "api", host: "api.example.com", user: "deploy", jumpHostID: web.id)
  let (directory, root) = try makeActionsDirectory([web, webAlt, api])
  defer { try? FileManager.default.removeItem(at: root) }
  let passwords = RecordingHostPasswords()
  passwords.saved = ["deploy@web.example.com:22", "deploy@api.example.com:22"]

  // web 与 web-alt 共用 endpoint：删 web 不能删掉 web-alt 还在用的口令。
  #expect(try SSHHostRemoval.remove(web.id, from: directory, passwords: passwords) == nil)
  #expect(passwords.deleted.isEmpty)
  #expect(directory.host(web.id) == nil)
  #expect(directory.host(api.id)?.jumpHostID == nil)

  // api 的口令没人共用，删主机时一起删。
  #expect(try SSHHostRemoval.remove(api.id, from: directory, passwords: passwords) == nil)
  #expect(passwords.deleted == ["deploy@api.example.com:22"])

  // 默认项保留在目录里。
  _ = try SSHHostRemoval.remove(SSHHostProfile.defaultsProfileID, from: directory, passwords: passwords)
  #expect(directory.hosts.contains { $0.isDefaults })
  #expect(throws: SSHHostEditingError.unknownHost) {
    try SSHHostEditing.savedHost(SSHHostProfile.defaultsProfileID, in: directory)
  }
}

@Test("复制主机：新 ID、名称加「副本」，导入组的副本放到未分组；全部连接字段原样带上")
@MainActor
func hostEditingDuplicateCarriesFields() throws {
  let imported = SSHHostProfile(
    name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1", port: 32222, user: "root",
    identityFiles: ["~/.orbstack/ssh/id_ed25519"], identitiesOnly: true,
    knownHostsFiles: ["~/.orbstack/ssh/known_hosts"], identityAgent: "~/agent.sock",
    tags: ["prod", "web"], vaultKeyIDs: [UUID()])
  let (directory, root) = try makeActionsDirectory([imported])
  defer { try? FileManager.default.removeItem(at: root) }

  let copy = try SSHHostEditing.duplicate(imported.id, in: directory)
  #expect(copy.id != imported.id)
  #expect(copy.name == L("\(imported.name) 副本"))
  #expect(copy.group == nil)
  #expect(copy.host == imported.host && copy.port == imported.port && copy.user == imported.user)
  #expect(copy.identityFiles == imported.identityFiles)
  #expect(copy.identitiesOnly == true && copy.knownHostsFiles == imported.knownHostsFiles)
  #expect(copy.identityAgent == imported.identityAgent && copy.tags == imported.tags)
  #expect(copy.vaultKeyIDs == imported.vaultKeyIDs)
  #expect(directory.host(copy.id) == copy)
  #expect(throws: SSHHostEditingError.unknownHost) { try SSHHostEditing.duplicate(UUID(), in: directory) }
}

@Test("导入 ~/.ssh/config：合并进导入组并落盘，跳板映射到已导入主机，汇总带被忽略的选项；内容不变时不写文件")
@MainActor
func hostDirectoryMergesSSHConfig() throws {
  let (directory, root) = try makeActionsDirectory([])
  defer { try? FileManager.default.removeItem(at: root) }
  let listing = SSHConfigListing(
    hosts: [
      SSHConfigHostEntry(alias: "bastion", hostName: "bastion.example.com", user: "ops"),
      SSHConfigHostEntry(alias: "db", hostName: "10.0.0.5", proxyJump: "ops@bastion:22"),
    ],
    ignored: [SSHConfigIgnoredOption(file: "~/.ssh/config", line: 12, option: "Match", reason: "unsupported")])

  let result = try directory.mergeSSHConfig(listing)
  #expect(result.added == 2)
  #expect(result.ignored.first?.option == "Match")
  let saved = try SSHHostStore(fileURL: directory.store.fileURL).load()
  let bastion = try #require(saved.first { $0.name == "bastion" })
  #expect(bastion.group == SSHHostProfile.importedGroup)
  #expect(saved.first { $0.name == "db" }?.jumpHostID == bastion.id)

  // 再导入一次：全部未变，文件不重写。
  let modified = try FileManager.default.attributesOfItem(atPath: directory.store.fileURL.path)[.modificationDate]
    as? Date
  let again = try directory.mergeSSHConfig(listing)
  #expect(again.added == 0 && again.unchanged == 2)
  #expect(
    try FileManager.default.attributesOfItem(atPath: directory.store.fileURL.path)[.modificationDate] as? Date
      == modified)
}

@Test("~/.ssh/config 不存在时建 0700 目录与 0600 空文件；已存在的文件原样保留")
@MainActor
func hostEditingEnsuresPrivateSSHConfig() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterSSHConfig-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("ssh/config")

  try SSHHostEditing.ensureSSHConfigFile(at: url)
  let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
  let directoryMode = try FileManager.default.attributesOfItem(
    atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
  #expect(fileMode == 0o600)
  #expect(directoryMode == 0o700)
  #expect(try Data(contentsOf: url).isEmpty)

  try "Host keep\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
  try SSHHostEditing.ensureSSHConfigFile(at: url)
  #expect(try String(contentsOf: url, encoding: .utf8) == "Host keep\n")
  #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o644)
}
