// 失败命令的纠错建议模型与解析入口；具体规则在 CommandCorrectionRules.swift。
import Foundation

/// 一条针对刚失败命令的修正建议。控制器在下一条空 prompt 把首条作为 ghost，
/// 其余进入候选面板；`kind` 只用于挑选说明文案，不影响插入字节。
public struct CommandCorrection: Equatable, Sendable {
  /// 建议的语义类别。
  public enum Kind: Equatable, Sendable {
    /// 命令名打错（`gti` → `git`）。
    case typoCommand
    /// 子命令打错，由工具自己的 "did you mean" 给出。
    case typoSubcommand
    /// `git push` 因远端领先被拒，先 `pull --rebase`。
    case pullBeforePush
    /// 想新建的分支已存在，改为切换过去。
    case switchExistingBranch
    /// `cd` 的目录不存在，换成当前目录里名称最接近的目录。
    case nearestDirectory
    /// Terraform 工作区未初始化，先 `init`。
    case terraformInit
    /// 权限不足，以 `sudo` 重试。
    case elevatePrivileges
    /// 命令没装，用包运行器（npx / uvx / bundle exec …）临时执行。
    case packageRunner(runner: String)
  }

  public let command: String
  public let kind: Kind

  public init(command: String, kind: Kind) {
    self.command = command
    self.kind = kind
  }
}

/// 规则需要的外部事实。磁盘访问通过闭包注入，Core 自己不碰文件系统；
/// 闭包都是惰性的，只有对应规则命中时才调用。
public struct CommandCorrectionContext: Sendable {
  /// 命令退出码；nil 表示 shell 没报告。
  public var exitStatus: Int?
  /// 规格库与别名里已知的命令名，用于命令名拼写纠错。
  public var knownCommands: Set<String>
  /// 列出当前目录下某个相对子路径（"" 表示 cwd 本身）里的**目录名**。
  /// 返回空数组表示无法列出或没有目录。
  public var directoryEntries: @Sendable (_ relativeParent: String) -> [String]
  /// 相对当前目录判断路径是否存在，包运行器建议用它找项目标记文件。
  public var fileExists: @Sendable (_ relativePath: String) -> Bool

  public init(
    exitStatus: Int? = nil,
    knownCommands: Set<String> = [],
    directoryEntries: @escaping @Sendable (String) -> [String] = { _ in [] },
    fileExists: @escaping @Sendable (String) -> Bool = { _ in false }
  ) {
    self.exitStatus = exitStatus
    self.knownCommands = knownCommands
    self.directoryEntries = directoryEntries
    self.fileExists = fileExists
  }
}

public enum CommandCorrectionParser {
  /// 单条建议最多返回的候选数。
  public static let maximumSuggestions = 3

  /// 兼容旧调用：只返回首条建议的命令文本。
  public static func suggestion(
    command: String,
    output: String,
    knownCommands: Set<String>
  ) -> String? {
    suggestions(
      command: command, output: output,
      context: CommandCorrectionContext(knownCommands: knownCommands)
    ).first?.command
  }

  /// 按确定性从高到低返回修正建议：工具自己给出的更正 > 结构性规则（push/branch/
  /// terraform/cd）> 命令名拼写 > 包运行器 > sudo。同一命令文本只保留一条，
  /// 与原命令相同的建议丢弃。
  public static func suggestions(
    command: String,
    output: String,
    context: CommandCorrectionContext
  ) -> [CommandCorrection] {
    guard command.utf8.count <= 4_096, output.utf8.count <= 128 * 1_024 else { return [] }
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard !tokens.isEmpty else { return [] }
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let input = CommandCorrectionRules.Input(
      command: trimmedCommand, tokens: tokens, output: output, context: context)

    var result: [CommandCorrection] = []
    func add(_ correction: CommandCorrection?) {
      guard let correction, result.count < maximumSuggestions,
        correction.command != trimmedCommand,
        !result.contains(where: { $0.command == correction.command })
      else { return }
      result.append(correction)
    }
    add(CommandCorrectionRules.toolSuggestedSubcommand(input))
    add(CommandCorrectionRules.pullBeforePush(input))
    add(CommandCorrectionRules.switchExistingBranch(input))
    add(CommandCorrectionRules.terraformInit(input))
    add(CommandCorrectionRules.nearestDirectory(input))
    add(CommandCorrectionRules.typoCommand(input))
    add(CommandCorrectionRules.packageRunner(input))
    add(CommandCorrectionRules.elevatePrivileges(input))
    return result
  }
}
