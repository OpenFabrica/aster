// 原生敏感词规则的边界用例；只用合成的测试值。
import Testing
@testable import AsterCore

@Test("词频保留敏感选项名但跳过值，赋值形式整词跳过")
func completionPrivacyTokenFilteringIsIndependent() {
  #expect(CompletionPrivacy.recordableArguments([
    "--TOKEN", "synthetic", "tail", "--token=synthetic", "TOKEN=synthetic", "--token=", "after",
  ]) == ["--TOKEN", "tail", "after"])
  #expect(CompletionPrivacy.recordableArguments(["-p", "123", "--auth_token=synthetic"]) == [
    "-p", "--auth_token=synthetic",
  ])
}

@Test("整行敏感规则使用原版前缀与长短选项边界", arguments: [
  ("tool --token", false), ("tool --TOKEN synthetic", true),
  ("tool --token=", false), ("tool SERVICE_AUTH_TOKEN=synthetic", true),
  ("tool sk-", true), ("tool SK-short", false), ("tool ghp_", true),
  ("tool -p12345", false), ("tool -p1234x", true), ("tool -pabc", false),
  ("tool https://user:@host", true), ("tool https://host/path:user@host", false),
  ("tool BEARER synthetic", true), ("tool Authorization:", true),
])
func completionPrivacyMatchesNativeBoundaries(_ sample: (String, Bool)) {
  #expect(CompletionPrivacy.containsSecret(sample.0) == sample.1)
}
