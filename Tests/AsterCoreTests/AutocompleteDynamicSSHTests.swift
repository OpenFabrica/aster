import Foundation
import Testing

@testable import AsterCore

private func makeHome() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-ssh-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
  return url.standardizedFileURL
}

private func write(_ contents: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try contents.write(to: url, atomically: true, encoding: .utf8)
}

@Test("ssh / mosh 的主机参数映射到 sshHosts，且是机器级来源")
func sshArgumentMapsToHostSource() {
  let argument = AutocompleteArgumentSpec(name: "user@hostname")
  #expect(AutocompleteDynamicSource.sources(for: argument, commandPath: ["ssh"]) == [.sshHosts])
  #expect(AutocompleteDynamicSource.sources(for: argument, commandPath: ["mosh"]) == [.sshHosts])
  #expect(AutocompleteDynamicSource.sources(for: AutocompleteArgumentSpec(name: "sources"), commandPath: ["scp"]).isEmpty)
  #expect(AutocompleteDynamicSource.sshHosts.isMachineScoped)
  #expect(!AutocompleteDynamicSource.gitLocalBranches.isMachineScoped)
}

@Test("SSH 主机来自 config 的 Host（含 Include）与 known_hosts，通配与哈希条目跳过")
func sshHostsReadConfigAndKnownHosts() throws {
  let home = try makeHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let ssh = home.appendingPathComponent(".ssh")
  try write(
    """
    # 注释
    Include conf.d/work
    Host build-mac bastion
      HostName 10.0.0.2
    Host *.internal !*.staging.internal
    Host=db-primary
    Match host foo
    """, to: ssh.appendingPathComponent("config"))
  try write("Host ci-runner\n  User ci\n", to: ssh.appendingPathComponent("conf.d/work"))
  try write(
    """
    github.com,140.82.112.3 ssh-ed25519 AAAA
    [gitea.local]:2222 ssh-rsa AAAA
    |1|hashed|hashed ssh-rsa AAAA
    @cert-authority *.example.com ssh-rsa AAAA
    build-mac ssh-ed25519 AAAA
    """, to: ssh.appendingPathComponent("known_hosts"))

  let reader = AutocompleteDiskDynamicReader(environment: ["HOME": home.path])
  let items = reader.items(for: .sshHosts, directory: "/tmp")
  let names = items.map(\.name)
  #expect(names == ["ci-runner", "build-mac", "bastion", "db-primary", "github.com", "140.82.112.3", "gitea.local"])
  #expect(items.first { $0.name == "build-mac" }?.description == L("SSH 配置"))
  #expect(items.first { $0.name == "github.com" }?.description == L("已知主机"))
  #expect(items.first { $0.name == "build-mac" }?.rankBonus == 1)

  // 没有 HOME 或目录不存在：空结果，不崩溃。
  #expect(AutocompleteDiskDynamicReader(environment: [:]).items(for: .sshHosts, directory: "/tmp").isEmpty)
  #expect(AutocompleteDiskDynamicReader(environment: ["HOME": "/nonexistent"]).items(for: .sshHosts, directory: "/tmp").isEmpty)
}
