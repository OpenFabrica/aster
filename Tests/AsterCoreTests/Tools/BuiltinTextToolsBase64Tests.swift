// 内置文本工具的 Base64：编码、宽松解码（两种字母表、补位、折行）与「看起来像 Base64」的判断。
import Foundation
import Testing

@testable import AsterCore

@Suite("BuiltinTextToolsBase64")
struct BuiltinTextToolsBase64Tests {
  /// 编码是标准字母表、带补位，UTF-8 文本按字节编码。
  @Test(arguments: [
    ("", ""),
    ("a", "YQ=="),
    ("ab", "YWI="),
    ("abc", "YWJj"),
    ("hello world", "aGVsbG8gd29ybGQ="),
    ("你好", "5L2g5aW9"),
    ("subjects?", "c3ViamVjdHM/"),
    (">>>", "Pj4+"),
  ])
  func encodeProducesStandardPaddedBase64(text: String, expected: String) {
    #expect(BuiltinTextTools.base64Encode(text) == expected)
  }

  /// 解码接受标准与 URL 安全字母表，补位可省略，空白（含折行）被忽略。
  @Test(arguments: [
    ("aGVsbG8gd29ybGQ=", "hello world"),
    ("aGVsbG8gd29ybGQ", "hello world"),
    ("YQ", "a"),
    ("YWI", "ab"),
    ("aGVsbG8g\nd29ybGQ=", "hello world"),
    (" a G V s\tbG8g d29ybGQ= \r\n", "hello world"),
    ("c3ViamVjdHM/", "subjects?"),
    ("c3ViamVjdHM_", "subjects?"),
    ("Pj4+", ">>>"),
    ("Pj4-", ">>>"),
    ("YWI+", "ab>"),
    ("YWI-", "ab>"),
    ("5L2g5aW9", "你好"),
  ])
  func decodeAcceptsBothAlphabetsAndLooseFormatting(text: String, expected: String) {
    #expect(BuiltinTextTools.base64Decode(text) == expected)
  }

  /// 解码拒绝：空串、非法字符、混用字母表、补位位置或数量不对、长度不可能合法。
  @Test(arguments: [
    "", "   ", "====", "!!!!", "YWJj!", "YW$j",
    "Pj4+Pz8_", "Pz8/Pj4-",
    "YQ===", "Y===", "YQ=", "YWI==", "YWJj=", "YQ==YQ==", "=YQ=",
    "Y", "YWJjZ",
    "ＹＱ==",
  ])
  func decodeRejectsMalformedInput(text: String) {
    #expect(BuiltinTextTools.base64Decode(text) == nil)
  }

  /// 字节合法但不是 UTF-8 文本时 `base64Decode` 返回 nil，`base64Data` 仍能给出字节。
  @Test func decodeRequiresUTF8TextButDataDoesNot() {
    #expect(BuiltinTextTools.base64Decode("/w==") == nil)
    #expect(BuiltinTextTools.base64Decode("gA==") == nil)
    #expect(BuiltinTextTools.base64Data("/w==") == Data([0xFF]))
    #expect(BuiltinTextTools.base64Data("AAEC") == Data([0, 1, 2]))
    #expect(BuiltinTextTools.base64Data("YQ") == Data("a".utf8))
    #expect(BuiltinTextTools.base64Data("Y") == nil)
  }

  /// 编码再解码得到原文，包括多字节字符与空串之外的各种长度（补位 0/1/2 个）。
  @Test(arguments: ["a", "ab", "abc", "abcd", "Aster 工具箱 🧰", "line1\nline2\ttab\r\nend", "a/b+c=d?"])
  func encodeThenDecodeRoundTrips(text: String) {
    #expect(BuiltinTextTools.base64Decode(BuiltinTextTools.base64Encode(text)) == text)
  }

  /// 「看起来像 Base64」：至少 8 个非空白字符、字母表和补位合法、解码结果是非空可打印文本。
  @Test(arguments: [
    ("aGVsbG8gd29ybGQ=", true),
    ("aGVsbG8gd29ybGQ", true),
    ("aGVsbG8g\nd29ybGQ=", true),
    ("YWJjZA==", true),
    ("5L2g5aW95LiW55WM", true),
    ("c3ViamVjdHM_", true),
    // 换行与制表符是允许出现在解码结果里的空白。
    ("bGluZTEKbGluZTIJdGFiDQplbmQ=", true),
    // 解码结果合法，但非空白字符不足 8 个（空白不计数）。
    ("YWJjZGU", false),
    ("YWJj\nZGU", false),
    ("aGk=", false),
    ("", false),
    ("        ", false),
    // 普通单词碰巧符合字符集，解码出来不是 UTF-8 文本。
    ("keyboard", false),
    ("password", false),
    ("hello world!", false),
    // 解码结果含控制字符、替换字符或不是 UTF-8。
    ("AAECAwQFBgc=", false),
    ("YWJj77+9ZGVmZ2g=", false),
    ("//79/Pv6+Q==", false),
    // 两种字母表混用。
    ("Pj4+Pz8_Pj4+", false),
  ])
  func looksLikeBase64ChecksLengthAlphabetAndPrintableText(text: String, expected: Bool) {
    #expect(BuiltinTextTools.looksLikeBase64(text) == expected)
  }
}
