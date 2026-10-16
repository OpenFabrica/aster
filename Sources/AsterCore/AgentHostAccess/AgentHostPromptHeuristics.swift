// 判断一条仍在运行的命令是否在等用户输入（sudo 口令、确认、分页器）。
// 只在「开始标记已出现、结束标记未出现、屏幕至少 2 秒没变」时调用，避免把普通输出误判。
import Foundation

/// `needs_input` 的屏幕启发式。
public enum AgentHostPromptHeuristics {
  /// 屏幕静止多久后才判断是否在等输入（毫秒）。
  public static let quietMilliseconds = 2_000

  /// 不分大小写、出现在行内即算的片段。
  static let fragments = [
    "[sudo] password for", "password:", "passphrase", "(yes/no", "[y/n]", "(y/n)",
    "continue?", "press enter", "press return", "--more--", "(end)", "verification code",
  ]

  /// 屏幕最后一个非空行若像输入提示，返回去掉首尾空白的该行；否则 nil。
  ///
  /// Ghostty 读屏会去掉行尾空格，所以「以 `: ` / `? ` 结尾」实际判断的是以 `:` / `?` 结尾。
  /// 这条规则偏宽：一条恰好以冒号结尾、随后长时间沉默的输出也会被当成等输入，但代价只是
  /// agent 多调一次 `host.wait`，而漏判会让 agent 一直等到超时、用户却不知道终端在等他。
  public static func prompt(in screenText: String) -> String? {
    guard
      let line = screenText.replacingOccurrences(of: "\r", with: "")
        .split(separator: "\n", omittingEmptySubsequences: true)
        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    else { return nil }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let lowered = trimmed.lowercased()
    if fragments.contains(where: lowered.contains) { return trimmed }
    // less 的默认提示就是一个 `:`，也被这条覆盖。
    if trimmed.hasSuffix(":") || trimmed.hasSuffix("?") { return trimmed }
    return nil
  }
}
