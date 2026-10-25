// 忽略模式的大小写、Unicode scalar 和字面字符边界。
import Testing
@testable import AsterCore

@Test("忽略模式双方转小写，只解释星号和问号", arguments: [
  ("GIT Status", "git *", true), ("git status", "GIT *", true),
  ("tool abc", "tool a?c", true), ("tool a", "tool [a]", false),
  ("tool [A]", "tool [a]", true), ("tool ?", "tool \\?", false),
  ("tool \\x", "tool \\?", true), ("é", "?", true),
  ("e\u{301}", "?", false), ("e\u{301}", "??", true),
  ("", "*", true), ("x", "", false), ("abbbc", "a*b?c", true),
])
func completionIgnorePatternMatchesRecoveredGrammar(_ sample: (String, String, Bool)) {
  #expect(CompletionIgnorePattern.matches(command: sample.0, pattern: sample.1) == sample.2)
}
