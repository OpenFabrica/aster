// Cargo 动态候选：从 Cargo.toml 与 src/bin、examples 目录读 bin / example / feature / package。
import Foundation

extension AutocompleteDiskDynamicReader {
  /// `cargo run --bin <Tab>` 等的候选。向上查找最近的 Cargo.toml；读不到就没有候选。
  func cargoItems(_ source: AutocompleteDynamicSource, directory: String) -> [AutocompleteDynamicItem] {
    guard let manifestURL = cargoManifest(for: directory),
      let data = readFile(at: manifestURL, maximumBytes: limits.maximumFileBytes)
    else { return [] }
    let manifest = CargoManifestSummary(toml: String(decoding: data, as: UTF8.self))
    let root = manifestURL.deletingLastPathComponent()
    var names: [String] = []
    let description: String
    switch source {
    case .cargoBinaries:
      description = L("Cargo 二进制")
      names = manifest.binaries
      // 自动发现：src/main.rs 是以包名命名的 bin，src/bin/*.rs 与 src/bin/<name>/main.rs 各算一个。
      if let package = manifest.packageName,
        (try? root.appendingPathComponent("src/main.rs").resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      { names.append(package) }
      names += fileNames(at: root.appendingPathComponent("src/bin"), extension: "rs")
      names += directoryNames(at: root.appendingPathComponent("src/bin"))
    case .cargoExamples:
      description = L("Cargo 示例")
      names = manifest.examples
      names += fileNames(at: root.appendingPathComponent("examples"), extension: "rs")
      names += directoryNames(at: root.appendingPathComponent("examples"))
    case .cargoFeatures:
      description = L("Cargo feature")
      names = manifest.features
    case .cargoPackages:
      description = L("Cargo 包")
      if let package = manifest.packageName { names.append(package) }
      names += manifest.workspaceMembers.compactMap { member -> String? in
        guard !member.contains("*"), !member.contains("?") else { return nil }
        // 成员目录自己的 Cargo.toml 里的包名优先，读不到就用目录名。
        let memberManifest = root.appendingPathComponent(member).appendingPathComponent("Cargo.toml")
        if let data = readFile(at: memberManifest, maximumBytes: limits.maximumFileBytes),
          let name = CargoManifestSummary(toml: String(decoding: data, as: UTF8.self)).packageName
        { return name }
        return URL(fileURLWithPath: member).lastPathComponent
      }
    default:
      return []
    }
    var seen: Set<String> = []
    return names.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limits.maximumItems)
      .map { AutocompleteDynamicItem(name: $0, description: description) }
  }

  /// 向上找最近的 Cargo.toml，与 git 根查找同一上限。
  func cargoManifest(for directory: String) -> URL? {
    var current = URL(fileURLWithPath: directory).standardizedFileURL
    for _ in 0..<limits.maximumParentWalk {
      let candidate = current.appendingPathComponent("Cargo.toml")
      if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return candidate }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return nil
  }
}

/// Cargo.toml 的最小行级读取：只认 `[package] name`、`[[bin]]`/`[[example]]` 的 `name`、
/// `[features]` 的键与 `[workspace] members`。不是完整 TOML 解析器——补全只需要名字，
/// 多行字符串、内联表等写法读不出来时宁可少几个候选，也不引入解析器依赖。
struct CargoManifestSummary: Equatable {
  var packageName: String?
  var binaries: [String] = []
  var examples: [String] = []
  var features: [String] = []
  var workspaceMembers: [String] = []

  init(toml: String) {
    var table = ""
    var pendingArray: (key: String, buffer: String)?
    for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = Self.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      if var pending = pendingArray {
        pending.buffer += line
        if line.contains("]") {
          if pending.key == "members" { workspaceMembers += Self.stringArray(pending.buffer) }
          pendingArray = nil
        } else {
          pendingArray = pending
        }
        continue
      }
      guard !line.isEmpty else { continue }
      if line.hasPrefix("[") {
        table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let equal = line.firstIndex(of: "=") else { continue }
      let key = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
      switch table {
      case "package" where key == "name":
        packageName = Self.string(value)
      case "bin" where key == "name":
        if let name = Self.string(value) { binaries.append(name) }
      case "example" where key == "name":
        if let name = Self.string(value) { examples.append(name) }
      case "features":
        features.append(key)
      case "workspace" where key == "members":
        if value.contains("]") {
          workspaceMembers += Self.stringArray(value)
        } else {
          pendingArray = (key, value)
        }
      default:
        continue
      }
    }
  }

  /// 去掉 `#` 注释，但保留引号内的 `#`。
  static func stripComment(_ line: String) -> String {
    var quote: Character?
    var result = ""
    for character in line {
      if let active = quote {
        if character == active { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == "#" {
        break
      }
      result.append(character)
    }
    return result
  }

  /// `"name"` / `'name'` 形式的字符串字面量。
  static func string(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'", trimmed.last == first
    else { return nil }
    let inner = String(trimmed.dropFirst().dropLast())
    return inner.isEmpty ? nil : inner
  }

  /// `["a", "b"]` 形式的字符串数组字面量。
  static func stringArray(_ value: String) -> [String] {
    guard let open = value.firstIndex(of: "["), let close = value.lastIndex(of: "]"), open < close else { return [] }
    return value[value.index(after: open)..<close].split(separator: ",").compactMap { string(String($0)) }
  }
}
