import Testing

@testable import AsterCore

@Suite("命令词末段名")
struct ShellCommandTokenizerBasenameTests {
  /// 路径形态取最后一段，与原先 `URL.lastPathComponent` 的结果一致。
  @Test(
    "路径取最后一段",
    arguments: [
      ("/usr/bin/git", "git"),
      ("git", "git"),
      ("./bin/mysql", "mysql"),
      ("/usr/local/bin/", "bin"),
      ("/", "/"),
      ("", ""),
    ])
  func pathWords(word: String, expected: String) {
    #expect(ShellCommandTokenizer.basename(word) == expected)
  }

  /// ASTER-A：URL 形态但解析不了的词，按 SDK 14 链接时 `URL(fileURLWithPath:)` 会 fatalError。
  @Test(
    "URL 形态的词按普通字符串处理",
    arguments: [
      ("http://127.0.0.1:${XR_PORT:-8080}/healthz;", "healthz;"),
      ("https://host:port/x", "x"),
      ("http:", "http:"),
    ])
  func urlLikeWords(word: String, expected: String) {
    #expect(ShellCommandTokenizer.basename(word) == expected)
  }
}
