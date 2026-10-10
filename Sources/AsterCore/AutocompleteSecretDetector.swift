// 判断一条命令是否带着凭据（密码、令牌、密钥），供「跳过含凭据的命令」开关整条不学习。
import Foundation

/// 手写 token 扫描，不用正则：命令结束时在主线程调用，必须便宜；误报只会少学一条历史，
/// 漏报则会把秘密写进 learning.json，所以规则宁可偏保守地多判。
public enum AutocompleteSecretDetector {
  /// 值紧跟其后（或用 `=` 连着）就视为凭据的选项名。
  static let secretOptionNames: Set<String> = [
    "--access-key", "--access-token", "--api-key", "--auth", "--auth-token", "--client-secret",
    "--password", "--passwd", "--private-key", "--secret", "--secret-key", "--token",
  ]
  /// 环境变量名里出现这些片段就按凭据处理（`export AWS_SECRET_ACCESS_KEY=…`）。
  static let secretVariableFragments = [
    "PASSWORD", "PASSWD", "SECRET", "TOKEN", "API_KEY", "APIKEY", "ACCESS_KEY", "PRIVATE_KEY", "CREDENTIAL",
  ]
  /// `mysql -pSECRET` 这类把密码紧贴在短选项后的工具。
  static let inlinePasswordExecutables: Set<String> = ["mysql", "mariadb", "mysqldump", "mysqladmin"]

  /// 命令里是否出现凭据。空命令返回 false。
  public static func containsSecret(_ command: String) -> Bool {
    guard !command.isEmpty else { return false }
    if command.contains("-----BEGIN") && command.contains("PRIVATE KEY-----") { return true }
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard let executable = tokens.first else { return false }
    for (index, token) in tokens.enumerated() {
      let lowered = token.lowercased()
      // `--token xyz` / `--token=xyz`：有值才算，光写选项名没有泄露什么。
      if let equal = lowered.firstIndex(of: "=") {
        if secretOptionNames.contains(String(lowered[..<equal])), lowered.index(after: equal) < lowered.endIndex {
          return true
        }
      } else if secretOptionNames.contains(lowered), index + 1 < tokens.count {
        return true
      }
      if isSecretAssignment(token) { return true }
      if lowered.hasPrefix("authorization:"), lowered.split(separator: " ").count >= 3 { return true }
      if inlinePasswordExecutables.contains(executable), token.hasPrefix("-p"), token.count > 2 { return true }
      if looksLikeSecretValue(token) { return true }
      if hasEmbeddedURLCredential(token) { return true }
    }
    return false
  }

  /// `NAME=value` 且 NAME 像凭据变量、value 不是对另一个变量的引用。
  static func isSecretAssignment(_ token: String) -> Bool {
    guard let equal = token.firstIndex(of: "="), equal > token.startIndex else { return false }
    let name = token[..<equal]
    let value = token[token.index(after: equal)...]
    guard !value.isEmpty, !value.hasPrefix("$"),
      name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" })
    else { return false }
    let upper = name.uppercased()
    return secretVariableFragments.contains { upper.contains($0) }
  }

  /// 常见云服务与平台密钥的固定形态。
  static func looksLikeSecretValue(_ token: String) -> Bool {
    let value = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    func tail(after prefix: String, minimum: Int, allowed: CharacterSet = .alphanumerics) -> Bool {
      guard value.hasPrefix(prefix) else { return false }
      let rest = value.dropFirst(prefix.count)
      return rest.count >= minimum && rest.unicodeScalars.allSatisfy { allowed.contains($0) || $0 == "_" || $0 == "-" }
    }
    if value.hasPrefix("AKIA"), value.count == 20,
      value.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) })
    { return true }
    for prefix in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"] where tail(after: prefix, minimum: 30) { return true }
    if tail(after: "github_pat_", minimum: 30) { return true }
    if tail(after: "sk-", minimum: 20) { return true }
    if tail(after: "glpat-", minimum: 20) { return true }
    if tail(after: "AIza", minimum: 35) { return true }
    for prefix in ["xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-"] where tail(after: prefix, minimum: 10) { return true }
    return false
  }

  /// `https://user:pass@host` 形态的 URL 把密码直接写在命令里。
  static func hasEmbeddedURLCredential(_ token: String) -> Bool {
    guard let schemeEnd = token.range(of: "://") else { return false }
    let authority = token[schemeEnd.upperBound...]
    guard let at = authority.firstIndex(of: "@") else { return false }
    let userInfo = authority[..<at]
    guard let colon = userInfo.firstIndex(of: ":"), !userInfo.contains("/") else { return false }
    return userInfo.index(after: colon) < userInfo.endIndex
  }
}
