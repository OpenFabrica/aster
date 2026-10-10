// 失败命令的具体纠错规则。每条规则只读输入与注入的事实，不执行任何命令。
import Foundation

enum CommandCorrectionRules {
  /// 一次解析共享的输入；`loweredOutput` 只算一次，供多条规则做不区分大小写的包含判断。
  struct Input {
    /// 去掉首尾空白、保留引号的原始命令行；整行前缀类建议（`sudo …`）直接拼它。
    let command: String
    /// 解引号后的 token，用于判断命令名与子命令。
    let tokens: [String]
    let output: String
    let loweredOutput: String
    let context: CommandCorrectionContext

    init(command: String, tokens: [String], output: String, context: CommandCorrectionContext) {
      self.command = command
      self.tokens = tokens
      self.output = output
      self.loweredOutput = output.lowercased()
      self.context = context
    }

    var executable: String { tokens.first ?? "" }
    func outputContains(_ needle: String) -> Bool { loweredOutput.contains(needle.lowercased()) }
    func outputContainsAny(_ needles: [String]) -> Bool { needles.contains(where: outputContains) }
  }

  // MARK: - 工具自己给出的更正

  /// git 的 "The most similar command is" 与 npm/cargo/pip 等的 did-you-mean 文案。
  static func toolSuggestedSubcommand(_ input: Input) -> CommandCorrection? {
    guard input.tokens.count >= 2 else { return nil }
    if input.outputContains("most similar command") {
      let lines = input.output.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let marker = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("most similar command") }),
        marker + 1 < lines.count, !lines[marker + 1].isEmpty
      {
        var corrected = input.tokens
        corrected[1] = lines[marker + 1]
        return CommandCorrection(command: corrected.joined(separator: " "), kind: .typoSubcommand)
      }
    }
    if let subcommand = suggestedSubcommand(in: input.output) {
      var corrected = input.tokens
      corrected[1] = subcommand
      return CommandCorrection(command: corrected.joined(separator: " "), kind: .typoSubcommand)
    }
    return nil
  }

  private static func suggestedSubcommand(in output: String) -> String? {
    let patterns = [
      #"(?i)did you mean(?: this)?\??\s*(?:\r?\n)+\s*(?:(?:npm|cargo|pip|brew|rustup|git)\s+)?([A-Za-z0-9._-]+)"#,
      #"(?i)(?:similar name exists|maybe you meant)\s*:?\s*[`'\"]?([A-Za-z0-9._-]+)"#,
    ]
    for pattern in patterns {
      if let candidate = firstCapture(pattern, in: output), candidate.utf8.count <= 128 {
        return candidate
      }
    }
    return nil
  }

  // MARK: - 结构性规则

  /// `git push` 被拒：远端有新提交。强推（`--force*` / `-f`）是用户明确要覆盖，不建议。
  static func pullBeforePush(_ input: Input) -> CommandCorrection? {
    guard input.executable == "git", input.tokens.contains("push"),
      input.outputContains("updates were rejected because"),
      input.outputContainsAny(["remote contains work", "tip of your current branch is behind", "fetch first"]),
      !input.tokens.contains(where: { $0 == "-f" || $0.hasPrefix("--force") })
    else { return nil }
    return CommandCorrection(command: "git pull --rebase && \(input.command)", kind: .pullBeforePush)
  }

  /// 想新建的分支已经存在：`checkout -b X` → `checkout X`，其余（`switch -c` / `branch`）→ `switch X`。
  static func switchExistingBranch(_ input: Input) -> CommandCorrection? {
    guard input.executable == "git",
      let name = firstCapture(
        #"(?i)(?:fatal|error):\s*a branch named\s+['"`“]?([^'"`”\s]+)['"`”]?\s+already exists"#,
        in: input.output),
      isSafeBranchName(name)
    else { return nil }
    let verb = input.tokens.contains("checkout") ? "checkout" : "switch"
    return CommandCorrection(command: "git \(verb) \(name)", kind: .switchExistingBranch)
  }

  /// Terraform / OpenTofu 工作区没有初始化。
  static func terraformInit(_ input: Input) -> CommandCorrection? {
    guard input.executable == "terraform" || input.executable == "tofu",
      input.tokens.count >= 2, input.tokens[1] != "init",
      input.outputContainsAny([
        "initialization required", "has not been initialized",
        "backend initialization required", "backend reinitialization required",
        "run \"terraform init\"", "run terraform init",
      ])
    else { return nil }
    return CommandCorrection(command: "\(input.executable) init && \(input.command)", kind: .terraformInit)
  }

  /// `cd` 到不存在的目录：在父目录里找名称最接近的目录。只处理相对/绝对路径，
  /// `~` 需要主目录展开，交给 shell，这里不猜。
  static func nearestDirectory(_ input: Input) -> CommandCorrection? {
    guard input.executable == "cd" || input.executable == "pushd",
      let missing = missingDirectoryTarget(input), !missing.hasPrefix("~"),
      missing.utf8.count <= 1_024
    else { return nil }
    var components = missing.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let last = components.popLast(), last.utf8.count <= 255, last != "..", last != "." else { return nil }
    let parent = (missing.hasPrefix("/") ? "/" : "") + components.joined(separator: "/")
    let entries = input.context.directoryEntries(parent)
    guard let nearest = StringEditDistance.nearest(
      to: last, in: entries, maximumDistance: StringEditDistance.correctionTolerance(for: last)),
      nearest != last
    else { return nil }
    let corrected = parent.isEmpty || parent == "/" ? parent + nearest : parent + "/" + nearest
    var tokens = input.tokens
    if let index = tokens.firstIndex(where: { $0 == missing || $0 == missing + "/" }), index > 0 {
      tokens[index] = shellQuoted(corrected)
    } else {
      tokens = [input.executable, shellQuoted(corrected)]
    }
    return CommandCorrection(command: tokens.joined(separator: " "), kind: .nearestDirectory)
  }

  /// 从 zsh / bash / fish 三种 `cd` 报错文案里取出不存在的目标；都对不上时，
  /// 只要输出提到 no such file 且命令只有一个参数，就用那个参数。
  private static func missingDirectoryTarget(_ input: Input) -> String? {
    for rawLine in input.output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      let lowered = line.lowercased()
      // zsh: `cd: no such file or directory: porject`
      if let range = lowered.range(of: "no such file or directory: ") {
        let target = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !target.isEmpty { return target }
      }
      // bash: `bash: cd: porject: No such file or directory`
      if lowered.hasSuffix("no such file or directory"),
        let start = lowered.range(of: "cd: ")
      {
        let rest = line[start.upperBound...]
        if let colon = rest.range(of: ": ", options: .backwards) {
          let target = String(rest[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
          if !target.isEmpty { return target }
        }
      }
      // fish: `cd: The directory 'porject' does not exist`
      if lowered.contains("the directory"), lowered.contains("does not exist"),
        let target = firstCapture(#"[Tt]he directory\s+['"“]([^'"”]+)['"”]\s+does not exist"#, in: line)
      {
        return target
      }
    }
    if input.outputContains("no such file or directory"), input.tokens.count == 2 {
      return input.tokens[1]
    }
    return nil
  }

  // MARK: - 命令名拼写

  /// shell 报 command not found 时，在已知命令名里找编辑距离最近的一个。
  static func typoCommand(_ input: Input) -> CommandCorrection? {
    guard input.outputContains("command not found") else { return nil }
    let executable = input.executable
    guard !executable.isEmpty, executable.utf8.count <= 128 else { return nil }
    guard let closest = StringEditDistance.nearest(
      to: executable, in: input.context.knownCommands,
      maximumDistance: StringEditDistance.correctionTolerance(for: executable)),
      closest.lowercased() != executable.lowercased()
    else { return nil }
    return CommandCorrection(
      command: ([closest] + input.tokens.dropFirst()).joined(separator: " "), kind: .typoCommand)
  }

  /// 命令没装时改用包运行器执行；只看 127 / command not found，规则体在 PackageRunnerSuggestion。
  static func packageRunner(_ input: Input) -> CommandCorrection? {
    guard input.context.exitStatus == 127 || input.outputContains("command not found") else { return nil }
    return PackageRunnerSuggestion.suggestion(
      command: input.executable, commandLine: input.command, fileExists: input.context.fileExists)
  }

  // MARK: - 提权

  private static let privilegeInsensitiveExecutables: Set<String> = [
    "sudo", "doas", "su", "cd", "ssh", "scp", "sftp", "rsync", "git", "exit", "source", ".",
  ]

  /// 权限不足时以 `sudo` 重试。网络/密钥类的 "Permission denied (publickey)" 与管道、
  /// 重定向都不适用：`sudo` 只提升第一个进程的权限。
  static func elevatePrivileges(_ input: Input) -> CommandCorrection? {
    if let status = input.context.exitStatus, status == 0 { return nil }
    guard !privilegeInsensitiveExecutables.contains(input.executable),
      !input.command.contains(where: { "|<>;&".contains($0) }),
      input.outputContainsAny([
        "permission denied", "operation not permitted", "eacces", "must be run as root", "must be root",
      ]),
      !input.outputContainsAny(["publickey", "password", "authentication"])
    else { return nil }
    return CommandCorrection(command: "sudo \(input.command)", kind: .elevatePrivileges)
  }

  // MARK: - 工具

  private static func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
      let capture = Range(match.range(at: 1), in: text)
    else { return nil }
    let value = String(text[capture])
    return value.isEmpty ? nil : value
  }

  private static func isSafeBranchName(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= 255 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/+-"))
    return name.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  /// 目录名含空格或特殊字符时用单引号包起来，保证建议原样可执行。
  static func shellQuoted(_ value: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+@%/:=,~"))
    guard !value.unicodeScalars.allSatisfy({ safe.contains($0) }) else { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
