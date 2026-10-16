import Foundation
import Testing

@testable import AsterCore

// 测 SSHVaultMigration：按展开与规范化后的路径找引用、迁移保留默认项的保险库密钥、
// 默认项里带 %h 的模板不参与匹配、删除引用后空列表回到继承。

private let home = "/Users/tester"
/// 假的软链表：`~/.ssh/id_link` 指向 dotfiles 里的真实文件。
private let links = ["/Users/tester/.ssh/id_link": "/Users/tester/dotfiles/id_ed25519"]
private func canonicalize(_ path: String) -> String { links[path] ?? path }

@Test("引用查找：展开 ~、%r 与软链后比较路径，默认项的 %h 模板跳过")
func sshVaultMigrationFindsReferences() {
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", identityFiles: ["~/.ssh/%h.key", "~/.ssh/id_ed25519"])
  let tilde = SSHHostProfile(name: "tilde", host: "a", identityFiles: ["~/.ssh/id_ed25519"])
  let byUser = SSHHostProfile(name: "user", host: "b", user: "deploy", identityFiles: ["/keys/%r"])
  let link = SSHHostProfile(name: "link", host: "c", identityFiles: ["~/.ssh/id_link"])
  let other = SSHHostProfile(name: "other", host: "d", identityFiles: ["~/.ssh/id_rsa"])
  let hosts = [defaults, tilde, byUser, link, other]

  #expect(
    SSHVaultMigration.hostsReferencing(
      path: "/Users/tester/.ssh/id_ed25519", in: hosts, homeDirectory: home, localUser: "me",
      canonicalize: canonicalize) == [defaults.id, tilde.id])
  #expect(
    SSHVaultMigration.hostsReferencing(
      path: "/keys/deploy", in: hosts, homeDirectory: home, localUser: "me", canonicalize: canonicalize)
      == [byUser.id])
  #expect(
    SSHVaultMigration.hostsReferencing(
      path: "/Users/tester/dotfiles/id_ed25519", in: hosts, homeDirectory: home, localUser: "me",
      canonicalize: canonicalize) == [link.id])
  // 默认项的 %h 模板没有具体主机，不能算作引用。
  #expect(
    SSHVaultMigration.hostsReferencing(
      path: "/Users/tester/.ssh/a.key", in: hosts, homeDirectory: home, localUser: "me",
      canonicalize: canonicalize).isEmpty)
}

@Test("迁移：去掉指向原文件的条目并追加保险库 ID；原本继承的默认项密钥被保留")
func sshVaultMigrationReplacesReferences() {
  let inheritedKey = UUID()
  let newKey = UUID()
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", vaultKeyIDs: [inheritedKey])
  let inherits = SSHHostProfile(
    name: "a", host: "a", identityFiles: ["~/.ssh/id_ed25519", "~/.ssh/id_rsa"])
  let explicit = SSHHostProfile(
    name: "b", host: "b", identityFiles: ["~/.ssh/id_ed25519"], vaultKeyIDs: [newKey])
  let untouched = SSHHostProfile(name: "c", host: "c", identityFiles: ["~/.ssh/id_rsa"])

  let result = SSHVaultMigration.migratingReferences(
    path: "/Users/tester/.ssh/id_ed25519", to: newKey, in: [defaults, inherits, explicit, untouched],
    homeDirectory: home, localUser: "me", canonicalize: canonicalize)
  #expect(result.changed == [inherits.id, explicit.id])
  #expect(result.hosts[0] == defaults)
  #expect(result.hosts[1].identityFiles == ["~/.ssh/id_rsa"])
  #expect(result.hosts[1].vaultKeyIDs == [inheritedKey, newKey])
  #expect(result.hosts[2].identityFiles.isEmpty)
  #expect(result.hosts[2].vaultKeyIDs == [newKey])
  #expect(result.hosts[3] == untouched)
}

@Test("删除引用：只动引用了它的主机，列表变空时回到继承（nil）")
func sshVaultMigrationRemovesReferences() {
  let gone = UUID()
  let kept = UUID()
  let only = SSHHostProfile(name: "a", host: "a", vaultKeyIDs: [gone])
  let mixed = SSHHostProfile(name: "b", host: "b", vaultKeyIDs: [gone, kept])
  let none = SSHHostProfile(name: "c", host: "c")
  let next = SSHVaultMigration.removingReferences(to: gone, in: [only, mixed, none])
  #expect(next[0].vaultKeyIDs == nil)
  #expect(next[1].vaultKeyIDs == [kept])
  #expect(next[2] == none)
  #expect(SSHVaultMigration.hostsUsing(kept, in: next) == [mixed.id])
}
