// 原版词频与整行历史分别过滤敏感内容，两个入口不能合并。
import Foundation

public enum CompletionPrivacy {
  private static let sensitiveFlags: Set<String> = [
    "-p", "--authorization", "--passwd", "--apikey", "--secret", "--api-key", "--token",
    "--pass", "--auth", "--key", "--password", "--secret-key", "--credential",
    "--access-token", "--private-key", "--credentials",
  ]

  /// 单独的敏感选项仍记录，但跳过紧随值；赋值形式直接跳过整个 token。
  /// 此规则始终启用，不受整行 skipSecrets 开关影响。
  public static func recordableArguments(_ tokens: [String]) -> [String] {
    var skipNext = false
    var result: [String] = []
    for token in tokens {
      if skipNext { skipNext = false; continue }
      let lowered = token.lowercased()
      if let equal = lowered.firstIndex(of: "=") {
        let key = String(lowered[..<equal])
        if sensitiveFlags.contains(key) || sensitiveFlags.contains("--" + key) { continue }
      }
      result.append(token)
      skipNext = sensitiveFlags.contains(lowered)
    }
    return result
  }

  /// skipSecrets 启用时整行是否跳过，规则来自原生 record 的独立整行分支。
  /// 不与 Agent 的脱敏器共用：这里的短选项和前缀判断故意保持原版边界。
  public static func containsSecret(_ line: String) -> Bool {
    let tokens = ShellCommandTokenizer.tokenize(line).tokens
    let fragments = [
      "password", "passwd", "secret", "token", "apikey", "api_key", "api-key",
      "credential", "auth", "access_key", "access-key", "private_key", "private-key",
    ]
    let prefixes = [
      "sk-", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-",
      "xoxa-", "xoxs-", "AKIA", "ASIA", "AIza", "ya29.",
    ]
    for (index, token) in tokens.enumerated() {
      if sensitiveFlags.contains(token.lowercased()) && index + 1 < tokens.count { return true }
      if let equal = token.firstIndex(of: "="), token.index(after: equal) < token.endIndex {
        let key = token[..<equal].drop(while: { $0 == "-" }).lowercased()
        if fragments.contains(where: key.contains) { return true }
      }
      if prefixes.contains(where: token.hasPrefix) { return true }
      if token.hasPrefix("-p"), token.utf8.count > 6,
        token.utf8.dropFirst(2).contains(where: { $0 < 48 || $0 > 57 })
      { return true }
      if let scheme = token.range(of: "://") {
        let authority = token[scheme.upperBound...]
        if let at = authority.firstIndex(of: "@") {
          let credentials = authority[..<at]
          if credentials.contains(":") && !credentials.contains("/") { return true }
        }
      }
    }
    let lowered = line.lowercased()
    return lowered.contains("bearer ") || lowered.contains("authorization:")
  }
}
