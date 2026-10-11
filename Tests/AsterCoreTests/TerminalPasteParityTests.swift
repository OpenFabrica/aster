// 粘贴保护与 Otty 对齐的放行规则，以及文件路径的 Shell 转义。
import Testing

@testable import AsterCore

@Test("命令正在运行时多行粘贴不再确认，控制字符仍然确认")
func pasteProtectionSkipsWhileCommandRuns() {
  let multiline = PasteRiskAnalyzer.analyze("line one\nline two\n")
  #expect(
    !PasteProtectionPolicy.requiresConfirmation(
      for: multiline, protectionEnabled: true, isCommandRunning: true))
  #expect(
    PasteProtectionPolicy.requiresConfirmation(
      for: multiline, protectionEnabled: true, isCommandRunning: false))

  let control = PasteRiskAnalyzer.analyze("ok\u{1B}[201~\nrm -rf ~")
  #expect(
    PasteProtectionPolicy.requiresConfirmation(
      for: control, protectionEnabled: true, isCommandRunning: true))
}

@Test("关闭“信任括号粘贴”后，括号模式下的多行粘贴仍需确认")
func pasteProtectionRespectsUntrustedBracketedPaste() {
  let multiline = PasteRiskAnalyzer.analyze("echo one\necho two")
  #expect(
    PasteProtectionPolicy.requiresConfirmation(
      for: multiline,
      protectionEnabled: true,
      isBracketedPasteMode: true,
      treatsBracketedPasteAsSafe: false
    ))
}

@Test("文件路径逐个转义成 Shell 参数并以空格连接")
func shellPasteEscaperJoinsEscapedPaths() {
  #expect(ShellPasteEscaper.escapePaths([]) == nil)
  #expect(ShellPasteEscaper.escapePaths(["/tmp/a b.txt"]) == "'/tmp/a b.txt'")
  #expect(
    ShellPasteEscaper.escapePaths(["/tmp/it's", "/tmp/$x"]) == "'/tmp/it'\\''s' '/tmp/$x'")
}

@Test("粘贴文本去掉末尾所有回车，正文中间的换行保留")
func pasteTrimsTrailingNewlines() {
  #expect(TerminalClipboardText.trimmingTrailingNewlines(in: "ls -la\n") == "ls -la")
  #expect(TerminalClipboardText.trimmingTrailingNewlines(in: "ls\r\n\r\n") == "ls")
  #expect(TerminalClipboardText.trimmingTrailingNewlines(in: "a\nb\r") == "a\nb")
  #expect(TerminalClipboardText.trimmingTrailingNewlines(in: "keep  ") == "keep  ")
  #expect(TerminalClipboardText.trimmingTrailingNewlines(in: "\n\r\n").isEmpty)
}
