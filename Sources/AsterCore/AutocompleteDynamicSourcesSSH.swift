// SSH 主机名动态候选：只读 ~/.ssh/config 与 known_hosts，绝不执行 ssh。
import Foundation

extension AutocompleteDiskDynamicReader {
  /// `ssh <Tab>` 的主机列表。config 里的 `Host` 别名排在前面（它们是用户起的名字），
  /// known_hosts 里出现过的主机其次；哈希过的 known_hosts 条目无法还原，直接跳过。
  func sshHosts() -> [AutocompleteDynamicItem] {
    guard let home = environment["HOME"], home.hasPrefix("/") else { return [] }
    let sshDirectory = URL(fileURLWithPath: home).appendingPathComponent(".ssh")
    var items: [AutocompleteDynamicItem] = []
    var seen: Set<String> = []
    func add(_ name: String, description: String, rankBonus: Double) {
      guard Self.isCompletableHost(name), seen.insert(name).inserted, items.count < limits.maximumItems else { return }
      items.append(AutocompleteDynamicItem(name: name, description: description, rankBonus: rankBonus))
    }
    var includeBudget = 8
    for host in sshConfigHosts(at: sshDirectory.appendingPathComponent("config"), sshDirectory: sshDirectory, includeBudget: &includeBudget) {
      add(host, description: L("SSH 配置"), rankBonus: 1)
    }
    for file in ["known_hosts", "known_hosts2"] {
      for host in knownHosts(at: sshDirectory.appendingPathComponent(file)) {
        add(host, description: L("已知主机"), rankBonus: 0)
      }
    }
    return items
  }

  /// 解析一份 ssh_config 的 `Host` 行；`Include` 最多跟进 `includeBudget` 个文件，
  /// 相对路径按 OpenSSH 规则相对 ~/.ssh 解析，`~` 展开，不支持通配符。
  func sshConfigHosts(at url: URL, sshDirectory: URL, includeBudget: inout Int) -> [String] {
    guard let data = readFile(at: url, maximumBytes: limits.maximumFileBytes) else { return [] }
    var hosts: [String] = []
    for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      // `Host foo bar` 与 `Host=foo` 两种写法都合法。
      let parts = line.replacingOccurrences(of: "=", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
      guard let keyword = parts.first?.lowercased(), parts.count >= 2 else { continue }
      switch keyword {
      case "host":
        hosts.append(contentsOf: parts.dropFirst())
      case "include":
        for pattern in parts.dropFirst() where includeBudget > 0 && !pattern.contains("*") && !pattern.contains("?") {
          includeBudget -= 1
          let target: URL
          if pattern.hasPrefix("/") {
            target = URL(fileURLWithPath: pattern)
          } else if pattern.hasPrefix("~/") {
            target = sshDirectory.deletingLastPathComponent().appendingPathComponent(String(pattern.dropFirst(2)))
          } else {
            target = sshDirectory.appendingPathComponent(pattern)
          }
          hosts.append(contentsOf: sshConfigHosts(at: target, sshDirectory: sshDirectory, includeBudget: &includeBudget))
        }
      default:
        continue
      }
    }
    return hosts
  }

  /// 解析 known_hosts：首列逗号分隔的主机，`[host]:port` 取 host；`|1|` 哈希条目与
  /// `@cert-authority` / `@revoked` 标记行跳过。
  func knownHosts(at url: URL) -> [String] {
    guard let data = readFile(at: url, maximumBytes: limits.maximumFileBytes) else { return [] }
    var hosts: [String] = []
    for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
      guard let first = rawLine.split(whereSeparator: \.isWhitespace).first,
        !first.hasPrefix("#"), !first.hasPrefix("@"), !first.hasPrefix("|")
      else { continue }
      for entry in first.split(separator: ",") {
        var host = String(entry)
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
          host = String(host[host.index(after: host.startIndex)..<close])
        }
        hosts.append(host)
      }
      if hosts.count >= limits.maximumItems { break }
    }
    return hosts
  }

  /// 通配与否定模式不是可连接的主机名；带空白或控制字符的也不是。
  static func isCompletableHost(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 253 else { return false }
    return !name.contains(where: { "*?! ".contains($0) || $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 } == true })
  }
}
