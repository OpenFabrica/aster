// 脚本工具的 text 输出与失败信息：stdout 解码去换行、stderr 摘要、terminal 模式的命令行转义。
import Foundation
import Testing

@testable import AsterCore

@Suite("ScriptToolProtocolOutput")
struct ScriptToolProtocolOutputTests {
  // MARK: stdout

  /// 只去掉末尾一个换行（`\n` 或 `\r\n`）；`\r\n` 是一个整体，不会留下孤立的 `\r`。
  @Test(arguments: [
    ("abc", "abc"),
    ("abc\n", "abc"),
    ("abc\r\n", "abc"),
    ("abc\n\n", "abc\n"),
    ("abc\r\n\r\n", "abc\r\n"),
    ("abc\r", "abc\r"),
    ("abc \n", "abc "),
    ("a\nb\n", "a\nb"),
    ("a\r\nb\r\n", "a\r\nb"),
    ("你好\n", "你好"),
    ("\n", ""),
    ("\r\n", ""),
    ("", ""),
  ])
  func decodeTextRemovesOneTrailingNewline(text: String, expected: String) {
    #expect(ScriptToolProtocol.decodeText(Data(text.utf8)) == expected)
  }

  /// 非法 UTF-8 字节替换为 U+FFFD，其余内容与末尾换行处理不受影响。
  @Test func decodeTextReplacesInvalidBytes() {
    #expect(ScriptToolProtocol.decodeText(Data([0x61, 0xFF, 0x62, 0x0A])) == "a\u{FFFD}b")
    #expect(ScriptToolProtocol.decodeText(Data([0xE4, 0xBD])).contains("\u{FFFD}"))
    #expect(ScriptToolProtocol.decodeText(Data([0xFF, 0x0D, 0x0A])) == "\u{FFFD}")
  }

  // MARK: stderr

  /// 失败时显示的 stderr：解码、去首尾空白，中间的换行保留。
  @Test func stderrSummaryTrimsWhitespaceAndKeepsInnerLines() {
    #expect(ScriptToolProtocol.stderrSummary(Data("  error text \n".utf8)) == "error text")
    #expect(ScriptToolProtocol.stderrSummary(Data("line1\nline2\n\n".utf8)) == "line1\nline2")
    #expect(ScriptToolProtocol.stderrSummary(Data()) == "")
    #expect(ScriptToolProtocol.stderrSummary(Data(" \n\t ".utf8)) == "")
    #expect(ScriptToolProtocol.stderrSummary(Data([0x65, 0xFF])) == "e\u{FFFD}")
  }

  /// 最多显示 4 KiB（UTF-8 字节），在字符边界截断，多字节字符不会被切开。
  @Test func stderrSummaryCapsDisplayAtFourKiB() {
    let limit = ScriptToolProtocol.stderrDisplayLimit
    #expect(ScriptToolProtocol.stderrSummary(Data(String(repeating: "x", count: limit).utf8)).utf8.count == limit)
    #expect(ScriptToolProtocol.stderrSummary(Data(String(repeating: "x", count: limit + 1).utf8)).utf8.count == limit)
    #expect(ScriptToolProtocol.stderrSummary(Data(String(repeating: "x", count: 100_000).utf8)).utf8.count == limit)
    // 4096 = 3 × 1365 + 1，三字节字符只能放 1365 个（4095 字节）。
    let cjk = ScriptToolProtocol.stderrSummary(Data(String(repeating: "你", count: 2_000).utf8))
    #expect(cjk.count == 1_365)
    #expect(cjk.utf8.count == limit - 1)
  }

  /// 只解码前 64 KiB：之后的内容不参与摘要，所以被空白填满的前 64 KiB 之后的文字看不到。
  @Test func stderrSummaryReadsOnlyFirstSixtyFourKiB() {
    let limit = ScriptToolProtocol.stderrLimit
    let padding = Data(repeating: 0x20, count: limit)
    #expect(ScriptToolProtocol.stderrSummary(padding + Data("tail".utf8)) == "")
    #expect(ScriptToolProtocol.stderrSummary(Data("head".utf8) + padding + Data("tail".utf8)) == "head")
  }

  // MARK: terminal 命令行

  /// 每项按 POSIX 单引号转义后以空格连接：空格、`$`、`;`、`*`、引号与换行都不会被 shell 解释。
  @Test(arguments: [
    ([String](), ""),
    (["ls"], "'ls'"),
    (["echo", "hello world"], "'echo' 'hello world'"),
    (["echo", "it's"], #"'echo' 'it'\''s'"#),
    (["printf", "$HOME; rm -rf *"], "'printf' '$HOME; rm -rf *'"),
    (["echo", ""], "'echo' ''"),
    (["echo", "你好"], "'echo' '你好'"),
    (["echo", "a\nb"], "'echo' 'a\nb'"),
    (["echo", "\"q\" `x` $(y)"], "'echo' '\"q\" `x` $(y)'"),
  ])
  func terminalCommandLineQuotesEveryItem(command: [String], expected: String) {
    #expect(ScriptToolProtocol.terminalCommandLine(command) == expected)
  }
}
