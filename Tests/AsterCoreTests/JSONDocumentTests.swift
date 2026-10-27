import Foundation
import Testing

@testable import AsterCore

@Test("JSON 解析保留键顺序、重复键和数字原文")
func jsonParserPreservesOrderDuplicatesAndNumberLiterals() throws {
  let node = try JSONDocumentParser.parse(#"{"z": 1.0, "a": [12345678901234567890, -0.5e+3], "z": null, "s": "\u4e2d\n"}"#)
  #expect(node == .object([
    JSONMember(key: "z", value: .number("1.0")),
    JSONMember(key: "a", value: .array([.number("12345678901234567890"), .number("-0.5e+3")])),
    JSONMember(key: "z", value: .null),
    JSONMember(key: "s", value: .string("中\n")),
  ]))
  #expect(try JSONDocumentParser.parse("\u{FEFF} [true, false, {}] ") == .array([.bool(true), .bool(false), .object([])]))
  #expect(try JSONDocumentParser.parse(#""\ud83d\ude00""#) == .string("😀"))
}

@Test("JSON 错误给出按字符计数的行列与原因", arguments: [
  ("{\n  \"名\": tru\n}", JSONParseError.Reason.unexpectedCharacter, 2, 11),
  ("[1, 2", .unexpectedEnd, 1, 6),
  ("{\"a\": 01}", .unexpectedCharacter, 1, 8),
  ("[1.]", .invalidNumber, 1, 4),
  ("\"a\u{01}\"", .invalidString, 1, 3),
  ("{} []", .trailingContent, 1, 4),
])
func jsonParserReportsErrorPosition(text: String, reason: JSONParseError.Reason, line: Int, column: Int) {
  #expect(throws: JSONParseError(reason: reason, line: line, column: column)) {
    try JSONDocumentParser.parse(text)
  }
}

@Test("JSON 超深嵌套报错而不是栈溢出")
func jsonParserRejectsExcessiveDepth() throws {
  let depth = JSONDocumentParser.maximumDepth
  #expect(throws: Never.self) {
    try JSONDocumentParser.parse(String(repeating: "[", count: depth) + String(repeating: "]", count: depth))
  }
  do {
    _ = try JSONDocumentParser.parse(String(repeating: "[", count: 100_000))
    Issue.record("超深嵌套应当失败")
  } catch let error as JSONParseError {
    #expect(error.reason == .tooDeep)
  }
}

@Test("JSON 格式化只改空白：保留转义、数字原文和空容器")
func jsonFormatterRewritesWhitespaceOnly() throws {
  let source = #"{"b":"x\u4e2d\"y","n":1.50,"e":{},"l":[ ],"a":[1,{"k":null}]}"#
  let formatted = try JSONDocumentFormatter.format(source, indent: "    ")
  #expect(formatted == """
    {
        "b": "x\\u4e2d\\"y",
        "n": 1.50,
        "e": {},
        "l": [],
        "a": [
            1,
            {
                "k": null
            }
        ]
    }

    """)
  #expect(try JSONDocumentFormatter.minify(formatted) == #"{"b":"x\u4e2d\"y","n":1.50,"e":{},"l":[],"a":[1,{"k":null}]}"#)
  #expect(try JSONDocumentFormatter.format(formatted, indent: "    ") == formatted)
  #expect(throws: JSONParseError.self) { try JSONDocumentFormatter.format("{\"a\": }", indent: "  ") }
}

@Test("JSON 缩进检测沿用文档已有单位", arguments: [
  ("{\n    \"a\": 1\n}", "    "),
  ("{\n\t\"a\": 1\n}", "\t"),
  ("{\n  \"a\": {\n    \"b\": 1\n  }\n}", "  "),
  ("{\"a\":1}", "  "),
])
func jsonFormatterDetectsIndent(text: String, indent: String) {
  #expect(JSONDocumentFormatter.detectIndent(in: text) == indent)
}

@Test("JSON 序列化与路径用于树视图复制")
func jsonSerializeAndPathForTreeCopy() {
  let node = JSONNode.object([
    JSONMember(key: "t", value: .string("a\"b\n")),
    JSONMember(key: "x", value: .array([.number("1"), .bool(false)])),
  ])
  #expect(JSONDocumentFormatter.serialize(node, indent: "  ") == """
    {
      "t": "a\\"b\\n",
      "x": [
        1,
        false
      ]
    }
    """)
  #expect(JSONPath.string([.key("flashes"), .index(0), .key("title")]) == "$.flashes[0].title")
  #expect(JSONPath.string([.key("a b"), .key("名"), .key("_ok$1")]) == #"$["a b"]["名"]._ok$1"#)
}
