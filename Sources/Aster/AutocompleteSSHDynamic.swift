import AsterCore
import Darwin
import Foundation

extension AutocompleteNativeDynamicProvider {
  func sshItems(context: AutocompleteDynamicContext) -> [CompletionDynamicItem] {
    guard Self.isSSHHostPosition(context), let home = environment["HOME"], !home.isEmpty else { return [] }
    let base = URL(fileURLWithPath: home).appendingPathComponent(".ssh")
    var visited = Set<String>()
    var configured: [String] = []
    for path in additionalSSHConfigPaths + [base.appendingPathComponent("config")] {
      configured += sshConfigHosts(at: path, home: home, context: context, visited: &visited, depth: 0)
    }
    let known = text(at: base.appendingPathComponent("known_hosts")).map(Self.knownSSHHosts) ?? []
    let prefix = context.currentToken.firstIndex(of: "@").map {
      String(context.currentToken[...$0])
    } ?? ""
    var seen = Set<String>()
    var items: [CompletionDynamicItem] = []
    for (hosts, description) in [(configured, "ssh config"), (known, "known host"), (recentSSHHosts, "recent")] {
      for host in hosts where context.hasTime {
        guard seen.insert(host).inserted else { continue }
        items.append(CompletionDynamicItem(name: prefix + host, description: description, kind: .argument))
      }
    }
    return items
  }

  static func isSSHHostPosition(_ context: AutocompleteDynamicContext) -> Bool {
    let valueFlags: Set<String> = ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
      "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"]
    let end = context.tokens.count - (context.currentToken.isEmpty ? 0 : 1)
    var index = 1
    while index < end {
      let token = context.tokens[index]
      guard token.hasPrefix("-") else { return false }
      index += valueFlags.contains(token) ? 2 : 1
    }
    return true
  }

  /// known_hosts 不验证公钥列；标记行使用第二字段，哈希、否定与通配字段不产生候选。
  static func knownSSHHosts(_ content: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in content.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("|") else { continue }
      let fields = line.split(whereSeparator: \.isWhitespace)
      let index = fields[0].hasPrefix("@") ? 1 : 0
      guard fields.indices.contains(index), !fields[index].hasPrefix("|") else { continue }
      for value in fields[index].split(separator: ",") {
        var host = String(value)
        if host.hasPrefix("[") {
          host = String(host.dropFirst().prefix { $0 != "]" })
        }
        if Self.isConcreteSSHHost(host), seen.insert(host).inserted { result.append(host) }
      }
    }
    return result
  }

  private static func isConcreteSSHHost(_ name: String) -> Bool {
    !name.isEmpty && !name.unicodeScalars.contains { "!*?".unicodeScalars.contains($0) }
  }

  private func sshConfigHosts(at path: URL, home: String, context: AutocompleteDynamicContext,
    visited: inout Set<String>, depth: Int
  ) -> [String] {
    guard context.hasTime, depth < 3 else { return [] }
    let canonical = path.resolvingSymlinksInPath().standardizedFileURL
    guard visited.insert(canonical.path).inserted, let content = text(at: canonical) else { return [] }
    var result: [String] = []
    for raw in content.split(separator: "\n") {
      guard context.hasTime else { break }
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let separator = line.firstIndex { $0.isWhitespace || $0 == "=" }
      guard let separator else { continue }
      let keyword = line[..<separator].lowercased()
      var rest = line[separator...].trimmingCharacters(in: .whitespaces)
      if rest.hasPrefix("=") { rest = rest.dropFirst().trimmingCharacters(in: .whitespaces) }
      let words = Self.sshWords(rest)
      if keyword == "host" {
        result += words.filter(Self.isConcreteSSHHost)
      } else if keyword == "include" {
        for pattern in words {
          let expanded: String
          if pattern == "~" { expanded = home }
          else if pattern.hasPrefix("~/") { expanded = home + String(pattern.dropFirst()) }
          else if pattern.hasPrefix("/") { expanded = pattern }
          else { expanded = home + "/.ssh/" + pattern }
          for included in Self.globPaths(expanded) {
            result += sshConfigHosts(at: URL(fileURLWithPath: included), home: home,
              context: context, visited: &visited, depth: depth + 1)
          }
        }
      }
    }
    return result
  }

  private static func globPaths(_ pattern: String) -> [String] {
    var matches = glob_t()
    defer { globfree(&matches) }
    guard glob(pattern, 0, nil, &matches) == 0, let paths = matches.gl_pathv else { return [] }
    return (0..<Int(matches.gl_pathc)).compactMap { paths[$0].map { String(cString: $0) } }
  }

  /// 原版只把双引号当分组标记；单引号、反斜杠和行内 '#' 都是字面字符。
  private static func sshWords(_ value: String) -> [String] {
    var words: [String] = []
    var word = ""
    var quoted = false
    for character in value {
      if character == "\"" { quoted.toggle() }
      else if character.isWhitespace && !quoted {
        if !word.isEmpty { words.append(word); word = "" }
      } else { word.append(character) }
    }
    if !word.isEmpty { words.append(word) }
    return words
  }
}
