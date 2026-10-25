import AsterCore
import Foundation

extension AutocompleteNativeDynamicProvider {
  func cargoItems(context: AutocompleteDynamicContext) -> [CompletionDynamicItem] {
    guard !context.directory.isEmpty, let flag = context.previousToken else { return [] }
    if flag == "--example" {
      let location = URL(fileURLWithPath: context.directory).appendingPathComponent("examples")
      let names = directoryNames(at: location, context: context)
      return names.filter { !$0.hasPrefix(".") }.compactMap {
        let name = $0.hasSuffix(".rs") ? String($0.dropLast(3)) : $0
        return name.isEmpty ? nil : CompletionDynamicItem(name: name, description: "example", kind: .argument)
      }.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }
    guard ["--bin", "--features", "-F", "--bench", "--package", "-p"].contains(flag) else { return [] }
    var directory = URL(fileURLWithPath: context.directory)
    for _ in 0..<10 {
      guard context.hasTime else { return [] }
      let manifest = directory.appendingPathComponent("Cargo.toml")
      if FileManager.default.fileExists(atPath: manifest.path) {
        guard let content = text(at: manifest) else { return [] }
        let parsed = AutocompleteCargoManifest(content)
        let names: [String]
        let description: String
        switch flag {
        case "--bin":
          names = parsed.binaries.isEmpty ? parsed.packageName.map { [$0] } ?? [] : parsed.binaries
          description = "bin"
        case "--features", "-F":
          names = parsed.features.filter { $0 != "default" }
          description = "feature"
        case "--bench":
          names = parsed.benches
          description = "bench"
        default:
          names = parsed.members
          description = "package"
        }
        return names.map { CompletionDynamicItem(name: $0, description: description, kind: .argument) }
      }
      let parent = directory.deletingLastPathComponent()
      guard parent.path != directory.path else { break }
      directory = parent
    }
    return []
  }
}

/// 原版 Cargo 读取器仅消费这些逐行字段，不处理 TOML 转义、续行或行尾注释。
struct AutocompleteCargoManifest {
  var binaries: [String] = []
  var benches: [String] = []
  var features: [String] = []
  var members: [String] = []
  var packageName: String?

  init(_ content: String) {
    var section = ""
    for raw in content.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("[["), line.hasSuffix("]]") {
        section = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        continue
      }
      if line.hasPrefix("["), line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        continue
      }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
      switch section {
      case "bin" where key == "name": binaries.append(Self.unquote(value))
      case "bench" where key == "name": benches.append(Self.unquote(value))
      case "features": features.append(key)
      case "package" where key == "name": packageName = Self.unquote(value)
      case "workspace" where key == "members":
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
          let open = value.startIndex
          members += value[value.index(after: open)..<close].split(separator: ",").map {
            Self.unquote($0.trimmingCharacters(in: .whitespacesAndNewlines))
          }.filter { !$0.isEmpty }
        }
      default: break
      }
    }
  }

  static func unquote(_ value: String) -> String {
    guard value.count >= 2, let first = value.first,
      (first == "\"" || first == "'"), value.last == first else { return value }
    return String(value.dropFirst().dropLast())
  }
}
