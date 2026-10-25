import AsterCore
import Foundation

extension AutocompleteNativeDynamicProvider {
  func packageItems(context: AutocompleteDynamicContext) -> [CompletionDynamicItem] {
    guard !context.directory.isEmpty else { return [] }
    let command = context.tokens.first ?? ""
    guard ["npm", "npx", "pnpm", "yarn", "bun", "bunx"].contains(command) else { return [] }
    let subcommand = context.commandPath.first
    let binaries = ["npx", "bunx"].contains(command)
      || ["exec", "dlx"].contains(subcommand ?? "")
      || (command != "yarn" && subcommand == "x")
    if binaries {
      let location = URL(fileURLWithPath: context.directory).appendingPathComponent("node_modules/.bin")
      let names = directoryNames(at: location, context: context)
      return names.filter { !$0.hasPrefix(".") }
        .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
        CompletionDynamicItem(name: $0, description: "bin", kind: .argument)
      }
    }
    let scripts = command == "yarn"
      ? subcommand == "run" || (subcommand == nil && context.argumentPosition == 0)
      : ["run", "run-script"].contains(subcommand ?? "")
    guard scripts else { return [] }
    var directory = URL(fileURLWithPath: context.directory)
    for _ in 0..<10 {
      guard context.hasTime else { return [] }
      let manifest = directory.appendingPathComponent("package.json")
      if FileManager.default.fileExists(atPath: manifest.path) {
        guard let content = text(at: manifest), let data = content.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let scripts = object["scripts"] as? [String: Any] else { return [] }
        return scripts.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.compactMap { key in
          guard let command = scripts[key] as? String else { return nil }
          return CompletionDynamicItem(name: key, description: command, kind: .argument)
        }
      }
      let parent = directory.deletingLastPathComponent()
      guard parent.path != directory.path else { break }
      directory = parent
    }
    return []
  }

  func makeItems(context: AutocompleteDynamicContext) -> [CompletionDynamicItem] {
    guard !context.directory.isEmpty else { return [] }
    let directory = URL(fileURLWithPath: context.directory)
    for name in ["GNUmakefile", "makefile", "Makefile"] {
      guard context.hasTime else { return [] }
      if let content = text(at: directory.appendingPathComponent(name)) {
        return Self.makeTargets(content).map {
          CompletionDynamicItem(name: $0, description: "target", kind: .argument)
        }
      }
    }
    return []
  }

  /// 不展开 make 变量或 include；扫描规则行和 .PHONY，保留首次出现的顺序。
  static func makeTargets(_ content: String) -> [String] {
    var found = Set<String>()
    var result: [String] = []
    for line in content.split(separator: "\n") {
      guard let first = line.first, !["#", " ", "\t"].contains(first),
        let colon = line.firstIndex(of: ":") else { continue }
      let phony = line.hasPrefix(".PHONY")
      guard phony || first != "." else { continue }
      let field = phony ? line[line.index(after: colon)...] : line[..<colon]
      guard phony || !field.contains("=") else { continue }
      for value in field.components(separatedBy: " ") {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("."),
          phony || (!value.contains("%") && !value.contains("$")),
          found.insert(value).inserted else { continue }
        result.append(value)
      }
    }
    return result
  }

  func composeItems(context: AutocompleteDynamicContext) -> [CompletionDynamicItem] {
    let path = context.root == "docker" ? Array(context.commandPath.dropFirst()) : context.commandPath
    guard context.root != "docker" || context.commandPath.first == "compose",
      let subcommand = path.first,
      ["up", "start", "restart", "pause", "unpause", "rm", "build", "ps", "stop", "create",
        "logs", "exec", "pull", "push", "port", "run", "top", "kill"].contains(subcommand),
      !context.directory.isEmpty else { return [] }
    for name in ["compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"] {
      guard context.hasTime else { return [] }
      let url = URL(fileURLWithPath: context.directory).appendingPathComponent(name)
      if let content = text(at: url) {
        return Self.composeServices(content).map {
          CompletionDynamicItem(name: $0, description: "service", kind: .argument)
        }
      }
    }
    return []
  }

  /// 原版是逐行缩进扫描，不展开 YAML alias、环境变量或 compose include。
  static func composeServices(_ content: String) -> [String] {
    var inServices = false
    var serviceIndent: Int?
    var names: [String] = []
    for raw in content.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let indent = raw.prefix { $0 == " " }.count
      if !inServices {
        inServices = indent == 0 && line.hasPrefix("services:")
        continue
      }
      if indent == 0 { break }
      if serviceIndent == nil { serviceIndent = indent }
      guard indent == serviceIndent, line.hasSuffix(":") else { continue }
      let name = line.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty, !name.contains(" ") { names.append(name) }
    }
    return names
  }
}
