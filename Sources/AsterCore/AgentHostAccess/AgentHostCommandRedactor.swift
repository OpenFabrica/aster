// 审计前的命令脱敏：把命令行里看得出来的凭据值换成 `***`。
// 审计按设计长期保留、会被导出，凭据进了审计就绕过了所有其它保护。
import Foundation

/// 命令脱敏器。规则逐条替换值，保留命令其余部分供追溯；规则没覆盖到、但
/// `AutocompleteSecretDetector` 仍判定含凭据的命令，整条只留可执行名。
public enum AgentHostCommandRedactor {
  public static let mask = "***"

  /// 脱敏结果。
  public struct Redaction: Equatable, Sendable {
    public var text: String
    public var redacted: Bool
  }

  /// 值紧跟其后（空格或 `=`）就视为凭据的长选项。
  static let secretOptions = [
    "password", "passwd", "token", "secret", "api-key", "apikey", "access-token", "auth-token",
    "client-secret", "secret-key", "access-key", "private-key",
  ]

  /// 变量名里出现这些片段就按凭据处理。
  static let secretNameFragments = ["PASSWORD", "PASSWD", "TOKEN", "SECRET", "CREDENTIAL", "APIKEY", "API_KEY"]

  /// 名字以 `KEY` 为一段时按凭据处理（`AWS_SECRET_ACCESS_KEY`、`STRIPE_KEY`），
  /// 但下面这些是公开标识：即使完整公开也不构成任何权限提升，脱敏反而丢掉排查线索。
  /// 往这里加名字前先确认它真不是秘密——误加一个真密钥是这套规则里代价最高的错误。
  static let publicNames: Set<String> = [
    "KEY_ID", "AWS_ACCESS_KEY_ID", "PUBKEY", "PUBLIC_KEY", "SSH_PUBLIC_KEY", "GPG_KEY_ID",
    "KEYID", "KEYMAP", "KEYBOARD", "KEY_PATH", "KEY_FILE", "SSH_KEY_PATH", "TOKEN_TYPE",
  ]

  /// 可执行文件允许 `-p<口令>` 紧贴写法的工具。
  static let inlinePasswordExecutables: Set<String> = ["mysql", "mariadb", "mysqldump", "mysqladmin"]

  /// 脱敏一条命令。
  public static func redact(_ command: String) -> Redaction {
    var text = command
    var changed = false
    func apply(_ pattern: String, template: String, options: NSRegularExpression.Options = []) {
      // 模式都是本文件里的常量，构造失败属于编程错误。
      let regex = try! NSRegularExpression(pattern: pattern, options: options)
      let range = NSRange(text.startIndex..., in: text)
      guard regex.firstMatch(in: text, range: range) != nil else { return }
      let replaced = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
      if replaced != text {
        text = replaced
        changed = true
      }
    }
    let value = #"(?:'[^']*'|"[^"]*"|[^\s;&|]+)"#

    // 私钥块整体替换。
    apply(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#, template: mask)
    // --password=x / --password x
    let options = secretOptions.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    apply(#"(--(?:"# + options + #"))(=|\s+)(?!\*\*\*)"# + value, template: "$1$2" + mask, options: .caseInsensitive)
    // NAME=value（值是 `$VAR` 引用时不算泄露）
    text = redactAssignments(text, valuePattern: value, changed: &changed)
    // scheme://user:pass@host
    apply(#"([A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)[^\s@/]+@"#, template: "$1" + mask + "@")
    // Authorization: Bearer xxx
    apply(#"((?i:authorization):\s*)(?:[A-Za-z]+\s+)?[^\s'"]+"#, template: "$1" + mask)
    // mysql -pSECRET
    if ShellCommandTokenizer.tokenize(command).tokens.contains(where: {
      inlinePasswordExecutables.contains(URL(fileURLWithPath: $0).lastPathComponent)
    }) {
      apply(#"(^|\s)-p(?!\*\*\*)[^\s;&|]+"#, template: "$1-p" + mask)
    }
    // 常见平台令牌的固定形态（ghp_、sk-、AKIA…）。
    for token in ShellCommandTokenizer.tokenize(text).tokens where AutocompleteSecretDetector.looksLikeSecretValue(token) {
      let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if text.contains(bare) {
        text = text.replacingOccurrences(of: bare, with: mask)
        changed = true
      }
    }
    // 兜底：规则一条都没命中、检测器仍认为原命令含凭据时，整条只留可执行名。
    // 先去掉白名单里的公开赋值（`AWS_ACCESS_KEY_ID=…`），否则检测器的片段规则会把它们误判成凭据。
    if !changed, AutocompleteSecretDetector.containsSecret(withoutPublicAssignments(command)) {
      let executable = ShellCommandTokenizer.tokenize(command).tokens.first ?? ""
      return Redaction(text: "\(executable) \(mask)", redacted: true)
    }
    return Redaction(text: text, redacted: changed)
  }

  /// 替换 `NAME=value` 里像凭据的值。逐个匹配判断名字，白名单里的公开标识原样保留。
  private static func redactAssignments(_ text: String, valuePattern: String, changed: inout Bool) -> String {
    let regex = try! NSRegularExpression(pattern: #"(^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=("# + valuePattern + ")")
    var result = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let nameRange = Range(match.range(at: 2), in: text),
        let valueRange = Range(match.range(at: 3), in: result)
      else { continue }
      let name = String(text[nameRange])
      let value = result[valueRange]
      guard isSecretName(name), !value.hasPrefix("$"), value != mask else { continue }
      result.replaceSubrange(valueRange, with: mask)
      changed = true
    }
    return result
  }

  /// 去掉名字不像凭据的 `NAME=value` 赋值，只给兜底检测用。
  private static func withoutPublicAssignments(_ command: String) -> String {
    let regex = try! NSRegularExpression(pattern: #"(^|\s)([A-Za-z_][A-Za-z0-9_]*)=\S*"#)
    var result = command
    for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)).reversed() {
      guard let nameRange = Range(match.range(at: 2), in: command), !isSecretName(String(command[nameRange])),
        let whole = Range(match.range, in: result)
      else { continue }
      result.replaceSubrange(whole, with: " ")
    }
    return result
  }

  /// 变量名是否像凭据：含口令 / 令牌 / 秘密片段，或有一段恰好是 `KEY`；公开标识除外。
  static func isSecretName(_ name: String) -> Bool {
    let upper = name.uppercased()
    if publicNames.contains(upper) || upper.hasSuffix("_KEY_ID") || upper.hasSuffix("_PUBLIC_KEY") {
      return false
    }
    if secretNameFragments.contains(where: upper.contains) { return true }
    return upper.split(separator: "_").contains("KEY")
  }
}
