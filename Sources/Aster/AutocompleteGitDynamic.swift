import AsterCore
import Foundation

enum AutocompleteGitDynamic {
  enum Source: CaseIterable {
    case branches, remoteBranches, remotes, tags, stashes, status, staged, unstaged

    var arguments: [String] {
      switch self {
      case .branches: ["git", "branch", "--no-color", "--sort=-committerdate"]
      case .remoteBranches: ["git", "branch", "--no-color", "--remotes", "--sort=-committerdate"]
      case .remotes: ["git", "remote"]
      case .tags: ["git", "tag", "--list", "--sort=-version:refname"]
      case .stashes: ["git", "stash", "list"]
      case .status: ["git", "--no-optional-locks", "status", "--short"]
      case .staged: ["git", "--no-optional-locks", "diff", "--cached", "--name-only"]
      case .unstaged: ["git", "--no-optional-locks", "diff", "--name-only"]
      }
    }
  }

  /// 枚举和顺序来自 0x10140ffc8；例如 reset 先给暂存路径，再给本地分支。
  static func sources(context: AutocompleteDynamicContext) -> [Source] {
    switch context.commandPath.first {
    case "checkout", "switch": return [.branches, .remoteBranches, .tags]
    case "merge", "rebase", "cherry-pick": return [.branches]
    case "branch": return context.hasFlag(["-d", "-D", "--delete"]) ? [.branches] : []
    case "tag": return context.hasFlag(["-d", "--delete"]) ? [.tags] : []
    case "log", "show": return [.branches, .tags]
    case "reset": return [.staged, .branches]
    case "add": return [.status]
    case "restore": return context.hasFlag(["--staged", "-S"]) ? [.staged] : [.unstaged]
    case "diff": return context.hasFlag(["--staged", "--cached"]) ? [.staged] : [.unstaged, .branches]
    case "push", "pull", "fetch":
      switch context.argumentPosition {
      case 0: return [.remotes]
      case 1: return [.branches]
      default: return []
      }
    case "stash":
      return context.commandPath.count > 1 && ["apply", "drop", "show", "pop"].contains(context.commandPath[1])
        ? [.stashes] : []
    default: return []
    }
  }

  /// 保持 Git 输出顺序。remote branch 去掉首个远端路径段，并用完整引用作为说明。
  static func parse(_ output: String, source: Source) -> [CompletionDynamicItem] {
    output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
      let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
      switch source {
      case .branches:
        let name = line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
        guard !name.isEmpty, !name.hasPrefix("(") else { return nil }
        return CompletionDynamicItem(name: name, description: "branch", kind: .argument)
      case .remoteBranches:
        guard !line.isEmpty, !line.contains(" -> ") else { return nil }
        let name = line.firstIndex(of: "/").map { String(line[line.index(after: $0)...]) } ?? line
        return CompletionDynamicItem(name: name, description: line, kind: .argument)
      case .remotes:
        guard !line.isEmpty else { return nil }
        return CompletionDynamicItem(name: line, description: "remote", kind: .argument)
      case .tags:
        guard !line.isEmpty else { return nil }
        return CompletionDynamicItem(name: line, description: "tag", kind: .argument)
      case .stashes:
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colon])
        let description = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return CompletionDynamicItem(name: name, description: description, kind: .argument)
      case .staged, .unstaged:
        guard !line.isEmpty else { return nil }
        return CompletionDynamicItem(name: stripQuotes(line),
          description: source == .staged ? "staged" : "modified", kind: .file)
      case .status:
        return statusItem(String(raw))
      }
    }
  }

  private static func statusItem(_ line: String) -> CompletionDynamicItem? {
    let scalars = Array(line.unicodeScalars)
    guard scalars.count >= 4, scalars[1] != " " else { return nil }
    var path = String(String.UnicodeScalarView(scalars.dropFirst(3)))
    if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
    path = stripQuotes(path)
    guard !path.isEmpty else { return nil }
    let description: String
    switch String(String.UnicodeScalarView(scalars.prefix(2))) {
    case "??": description = "untracked"
    case " M": description = "modified"
    case " D": description = "deleted"
    case "MM": description = "modified (partially staged)"
    case "AM": description = "added, then modified"
    default: description = String(String.UnicodeScalarView(scalars.prefix(2))).trimmingCharacters(in: .whitespaces)
    }
    return CompletionDynamicItem(name: path, description: description, kind: .file)
  }

  static func stripQuotes(_ value: String) -> String {
    guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
    return String(value.dropFirst().dropLast())
  }
}
