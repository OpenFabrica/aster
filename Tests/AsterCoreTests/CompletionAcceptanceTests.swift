// 接受补全的删除范围、字节单位及尾空格规则。
import Testing

@testable import AsterCore

private func acceptanceBytes(_ deletes: Int, _ insertion: String) -> [UInt8] {
  Array(repeating: UInt8(0x7f), count: deletes) + Array(insertion.utf8)
}

@Test("接受普通候选删除原始末尾 token 后插入完整文本及空格")
func completionAcceptanceReplacesLastToken() {
  let candidate = AutocompleteCandidate(insertText: "checkout", kind: .subcommand)
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "git chec")
    == acceptanceBytes(4, "checkout "))
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "git ")
    == acceptanceBytes(0, "checkout "))
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "")
    == acceptanceBytes(0, "checkout "))
}

@Test("删除按 Unicode scalar 计数，不按 UTF8 字节或组合字素计数")
func completionAcceptanceCountsUnicodeScalars() {
  let candidate = AutocompleteCandidate(insertText: "éclair", kind: .argument)
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "tool e\u{301}")
    == acceptanceBytes(2, "éclair "))
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "tool 🧑‍💻")
    == acceptanceBytes(3, "éclair "))
}

@Test("原始 token 删除包含引号及反斜杠，只有未转义未引号 ASCII 空格分隔", arguments: [
  ("tool \"two words\"", 11),
  ("tool 'two words'", 11),
  ("tool two\\ words", 10),
  ("tool \"two words ", 11),
  ("tool 'two\\ words'", 12),
  ("tool two\twords", 9),
  ("tool two\u{a0}words", 9),
])
func completionAcceptanceKeepsRawTokenSyntax(example: (String, Int)) {
  let candidate = AutocompleteCandidate(insertText: "replacement", kind: .argument)
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: example.0)
    == acceptanceBytes(example.1, "replacement "))
}

@Test("目录不加空格，已编码文件路径不会被二次转义")
func completionAcceptancePreservesEncodedPaths() {
  let folder = AutocompleteCandidate(insertText: "two\\ words/", displayText: "two words/", kind: .folder)
  #expect(CompletionAcceptance.bytes(candidate: folder, line: "cd tw")
    == acceptanceBytes(2, "two\\ words/"))
  let file = AutocompleteCandidate(insertText: "two\\ words.txt", displayText: "two words.txt", kind: .file)
  #expect(CompletionAcceptance.bytes(candidate: file, line: "cat tw")
    == acceptanceBytes(2, "two\\ words.txt "))
}

@Test("路径按原生字符集合转义，只有已输入 tilde 时保留首个 tilde 展开")
func completionAcceptanceEscapesPathLiteralsAndPreservesTypedTilde() {
  let raw = " ()&|;$!><`\\\"'*?[]{}~#^"
  let candidate = AutocompleteCandidate(insertText: "unused", displayText: raw, kind: .file)
  let escaped = raw.map { "\\" + String($0) }.joined()
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "cat ")
    == acceptanceBytes(0, escaped + " "))
  let home = AutocompleteCandidate(insertText: "unused", displayText: "~/two words/", kind: .folder)
  #expect(CompletionAcceptance.bytes(candidate: home, line: "cd ~")
    == acceptanceBytes(1, "~/two\\ words/"))
  #expect(CompletionAcceptance.bytes(candidate: home, line: "cd \"~\"")
    == acceptanceBytes(3, "~/two\\ words/"))
  #expect(CompletionAcceptance.bytes(candidate: home, line: "cd ")
    == acceptanceBytes(0, "\\~/two\\ words/"))
}

@Test("尚未恢复动作字段的候选保持旧只追加行为")
func completionAcceptanceKeepsLegacyBodyFallback() {
  let candidate = AutocompleteCandidate(insertText: "npm run build", kind: .readmeCommand)
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "npm run b") == Array("uild".utf8))
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "other") == nil)
}

@Test("历史和修正删除整行且不追加空格", arguments: [
  AutocompleteCandidateKind.learnedCommand, .correction,
])
func completionAcceptanceReplacesFullLine(kind: AutocompleteCandidateKind) {
  let candidate = AutocompleteCandidate(insertText: "git checkout main", kind: kind,
    replacement: .currentToken(start: 4))
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "git e\u{301}")
    == acceptanceBytes(6, "git checkout main"))
}

@Test("普通候选即使已有尾空格也无条件追加 ASCII 空格")
func completionAcceptanceAlwaysAppendsOrdinarySpace() {
  let candidate = AutocompleteCandidate(insertText: "value ", kind: .argument)
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "tool va")
    == acceptanceBytes(2, "value  "))
}

@Test("拒绝空值和能触发终端动作的候选控制字符", arguments: [
  "", "value\t", "value\n", "value\r", "value\0", "value\u{1b}", "value\u{7f}", "value\u{85}",
])
func completionAcceptanceRejectsUnsafeCandidate(text: String) {
  let candidate = AutocompleteCandidate(insertText: text, kind: .argument)
  #expect(CompletionAcceptance.bytes(candidate: candidate, line: "tool va") == nil)
}
