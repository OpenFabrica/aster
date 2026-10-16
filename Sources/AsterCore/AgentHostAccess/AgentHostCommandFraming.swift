// agent 远程执行的「标记符」协议：把命令包成一行敲进真实 SSH 终端，再从屏幕文本里
// 按一次性 nonce 找回输出与退出码。纯函数，不依赖 AppKit 或终端引擎，全部单测覆盖。
import Foundation

/// 注入行的构造与屏幕文本的解析。
///
/// 注入格式（N 为 12 位十六进制 nonce）：
/// ```
/// \x15 printf '\074aster:%s\076\n' Nb; eval '<cmd>'; printf '\074aster:%s:%s\076\n' Ne $?\r
/// ```
/// - 标记符的 `<` `>` 写成八进制、nonce 作为独立参数：回显的命令行里永远不会出现
///   `<aster:Nb>` 原文，解析不会被回显误命中。
/// - `eval` 在当前 Shell 执行：`cd`、`export` 跨命令保留；语法错误时 eval 返回非零，
///   结束标记照样打印，不会卡在 PS2。
/// - 行首 Ctrl-U 清掉用户在提示符上残留的半行输入；行首空格让 bash/zsh 不记历史。
/// - 只用 POSIX printf，不依赖 bash/zsh 扩展。
public enum AgentHostCommandFraming {
  /// 屏幕解析结果。
  public enum ParseResult: Equatable, Sendable {
    /// 还没看到开始标记（命令行还在回显或 Shell 还没执行到）。
    case notStarted
    /// 已开始未结束；`output` 是开始标记之后的已有输出。
    case running(output: String)
    /// 已结束。`beginSeen == false` 表示开始标记已滚出读取范围，输出只是尾部。
    case completed(exitCode: Int, output: String, beginSeen: Bool)
  }

  /// 生成一个 12 位小写十六进制 nonce。
  public static func makeNonce() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }

  /// nonce 必须是 12 位小写十六进制：它直接拼进 Shell 命令行与正则。
  public static func isValidNonce(_ nonce: String) -> Bool {
    nonce.utf8.count == 12 && nonce.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }
  }

  // MARK: - 注入

  /// 命令的注入字节（UTF-8 文本，末尾是 CR）。调用方须先 `validate(command:)`。
  public static func commandLine(command: String, nonce: String) -> String {
    precondition(isValidNonce(nonce), "nonce 必须是 12 位十六进制")
    return "\u{15} printf '\\074aster:%s\\076\\n' \(nonce)b; eval \(quoted(command)); "
      + "printf '\\074aster:%s:%s\\076\\n' \(nonce)e $?\r"
  }

  /// 就绪 / 重新同步探针。
  ///
  /// `true $?` 是给 fish 设的绊线：fish 在解析期就拒绝 `$?` 并打印 `fish: …`，整行不执行，
  /// 探针超时后据此报「不支持的 Shell」，而不是把命令敲进一个标记符协议跑不通的 Shell。
  /// 配置环境的探针顺带关掉分页器，避免 `git log`、`systemctl status` 卡在 `(END)`；并让
  /// bash（HISTCONTROL=ignorespace）与 zsh（HIST_IGNORE_SPACE）不把空格开头的注入行写进远端历史。
  public static func probeLine(nonce: String, configureEnvironment: Bool) -> String {
    precondition(isValidNonce(nonce), "nonce 必须是 12 位十六进制")
    let setup = configureEnvironment
      ? " export PAGER=cat GIT_PAGER=cat MANPAGER=cat SYSTEMD_PAGER=cat;"
        + " [ -n \"${ZSH_VERSION-}\" ] && setopt HIST_IGNORE_SPACE;"
        + " [ -n \"${BASH_VERSION-}\" ] && HISTCONTROL=\"ignorespace${HISTCONTROL:+:$HISTCONTROL}\";"
      : ""
    return "\u{15}\(setup) true $?; printf '\\074aster:%s:ready\\076\\n' \(nonce)\r"
  }

  /// 把命令放进单引号，并保证敲进 PTY 的只有可打印 ASCII 与换行。
  ///
  /// - `'` 写成 `'\''`。
  /// - 其余非可打印 ASCII 字节（Tab、0x80 以上的 UTF-8 字节等）一律移到引号外，用
  ///   `'"$(printf '\ooo…')"'` 拼回去，连续的字节合成一组。原因：Tab 原样敲进行编辑器会触发补全；
  ///   远端在 C / POSIX locale 下，bash readline 把 0x80 以上的字节当 Meta 键（如 0xAE 是 M-.，
  ///   插入上一条命令的最后一个参数），中文、emoji 会变成一串编辑命令而不是文本。
  /// - `$(…)` 只会去掉结尾换行，而换行从不走这条路径：它留在引号里，Shell 会进 PS2 继续读。
  ///   eval 因此收到与原命令逐字节相同的文本。
  /// - 代价：非 ASCII 字节在注入行里膨胀约 4 倍，`validate` 按转义后的长度限制单行。
  static func quoted(_ command: String) -> String {
    var result = "'"
    var pending: [UInt8] = []
    /// 把攒下的一组特殊字节写成一次 printf 八进制转义。
    func flush() {
      guard !pending.isEmpty else { return }
      let octal = pending.map { "\\" + String(format: "%03o", $0) }.joined()
      result += "'\"$(printf '\(octal)')\"'"
      pending.removeAll()
    }
    for byte in command.utf8 {
      if byte == UInt8(ascii: "\n") || (0x20...0x7E).contains(byte) {
        flush()
        if byte == UInt8(ascii: "'") {
          result += "'\\''"
        } else {
          result.unicodeScalars.append(Unicode.Scalar(byte))
        }
      } else {
        pending.append(byte)
      }
    }
    flush()
    return result + "'"
  }

  /// 命令的边界校验：非空、总长与单行长度有上限，拒绝 NUL、ESC、CR 等控制字符。
  ///
  /// 控制字符一旦敲进行编辑器就是按键（Ctrl-C、Ctrl-D、Esc 进 vi 模式），不是文本；
  /// 只放行换行（引号内续行）与 Tab（`quoted` 已转义）。单行长度按 `quoted` 转义后真正敲入的
  /// 字节计算：无行编辑的 sh 受规范模式行缓冲限制，非 ASCII 字符转义后约为原来的 4 倍。
  public static func validate(command: String) throws {
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AsterControlError.invalidParams("command 不能为空")
    }
    guard command.utf8.count <= AgentHostLimits.maximumCommandBytes else {
      throw AsterControlError.invalidParams("command 最多 \(AgentHostLimits.maximumCommandBytes) 字节")
    }
    for scalar in command.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
      if scalar == "\n" || scalar == "\t" { continue }
      throw AsterControlError.invalidParams("command 含控制字符（NUL、ESC、CR 等不可敲入）")
    }
    // 按每行转义后的长度计（不含整条命令首尾那一对单引号）：纯 ASCII 行与原来的字节数一致。
    for line in command.split(separator: "\n", omittingEmptySubsequences: false)
    where quoted(String(line)).utf8.count - 2 > AgentHostLimits.maximumCommandLineBytes {
      throw AsterControlError.invalidParams(
        "command 单行转义后最多 \(AgentHostLimits.maximumCommandLineBytes) 字节（非 ASCII 字符按约 4 倍计）")
    }
  }

  // MARK: - 解析

  /// 在屏幕文本里找当前 nonce 的开始 / 结束标记。
  ///
  /// 取最后一个开始标记（同一 nonce 只会出现一次，取最后是为了对重绘留余量）；
  /// 结束标记在行内任意位置都算（命令输出没有尾换行时它紧跟在输出后面）；
  /// 标记中间被插入的换行（极窄终端硬折行）也能容忍。旧 nonce 的标记一律无视。
  public static func parse(_ screenText: String, nonce: String) -> ParseResult {
    guard isValidNonce(nonce) else { return .notStarted }
    // 按标量判断 CR：Swift 把 "\r\n" 当成一个 Character，`contains("\r")` 看不到它。
    let text = screenText.unicodeScalars.contains("\r") ? screenText.replacingOccurrences(of: "\r", with: "") : screenText
    let range = NSRange(text.startIndex..., in: text)
    let beginMatch = beginPattern(nonce).matches(in: text, range: range).last
    let searchStart = beginMatch.map { NSMaxRange($0.range) } ?? 0
    let endMatch = endPattern(nonce).firstMatch(
      in: text, range: NSRange(location: searchStart, length: range.length - searchStart))

    let outputStart: String.Index
    if let beginMatch, let markerEnd = Range(beginMatch.range, in: text)?.upperBound {
      // 开始标记由 printf 带换行打印，输出从下一行开始。
      outputStart = text[markerEnd...].firstIndex(of: "\n").map(text.index(after:)) ?? text.endIndex
    } else {
      outputStart = text.startIndex
    }
    guard let endMatch else {
      return beginMatch == nil ? .notStarted : .running(output: String(text[outputStart...]))
    }
    guard let endRange = Range(endMatch.range, in: text),
      let codeRange = Range(endMatch.range(at: 1), in: text)
    else { return .notStarted }
    let digits = text[codeRange].filter(\.isNumber)
    let exitCode = Int(digits) ?? -1
    var output = outputStart <= endRange.lowerBound ? String(text[outputStart..<endRange.lowerBound]) : ""
    if output.hasSuffix("\n") { output.removeLast() }
    return .completed(exitCode: exitCode, output: output, beginSeen: beginMatch != nil)
  }

  /// 屏幕上是否出现了该 nonce 的就绪探针回应。
  public static func containsProbeReply(_ screenText: String, nonce: String) -> Bool {
    guard isValidNonce(nonce) else { return false }
    let text = screenText.replacingOccurrences(of: "\r", with: "")
    return tolerantPattern(literal: "<aster:\(nonce):ready>")
      .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// 开始标记 `<aster:Nb>`。
  private static func beginPattern(_ nonce: String) -> NSRegularExpression {
    tolerantPattern(literal: "<aster:\(nonce)b>")
  }

  /// 结束标记 `<aster:Ne:CODE>`，CODE 为捕获组 1（可能夹换行，调用方去掉）。
  private static func endPattern(_ nonce: String) -> NSRegularExpression {
    let prefix = tolerantSource("<aster:\(nonce)e:")
    // 模式只由转义后的字面量与固定片段组成，构造不会失败。
    return try! NSRegularExpression(pattern: prefix + "\\n?(\\d(?:\\n?\\d)*)\\n?>")
  }

  /// 字面量的「容忍换行」正则：相邻字符之间允许一个 `\n`。
  private static func tolerantPattern(literal: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: tolerantSource(literal))
  }

  private static func tolerantSource(_ literal: String) -> String {
    literal.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\n?")
  }

  // MARK: - 截断

  /// 输出超过预算时保留开头与结尾，中间写明省略了多少字节；按字符边界切，不切坏 UTF-8。
  public static func truncate(
    _ output: String, maximumBytes: Int, headBytes: Int = AgentHostLimits.truncationHeadBytes
  ) -> (text: String, truncated: Bool) {
    let total = output.utf8.count
    guard total > maximumBytes else { return (output, false) }
    let headBudget = min(headBytes, maximumBytes / 2)
    let head = prefix(output, maximumBytes: headBudget)
    let tail = suffix(output, maximumBytes: max(maximumBytes - headBudget, 0))
    let omitted = total - head.utf8.count - tail.utf8.count
    return ("\(head)\n[… \(omitted) bytes omitted …]\n\(tail)", true)
  }

  /// 不超过 `maximumBytes` 的最长字符前缀。
  static func prefix(_ text: String, maximumBytes: Int) -> String {
    var count = 0
    var end = text.startIndex
    for index in text.indices {
      let size = text[index].utf8.count
      guard count + size <= maximumBytes else { break }
      count += size
      end = text.index(after: index)
    }
    return String(text[..<end])
  }

  /// 不超过 `maximumBytes` 的最长字符后缀。
  static func suffix(_ text: String, maximumBytes: Int) -> String {
    var count = 0
    var start = text.endIndex
    while start > text.startIndex {
      let previous = text.index(before: start)
      let size = text[previous].utf8.count
      guard count + size <= maximumBytes else { break }
      count += size
      start = previous
    }
    return String(text[start...])
  }
}
