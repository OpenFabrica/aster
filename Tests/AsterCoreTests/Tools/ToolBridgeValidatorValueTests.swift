// 桥接的 JSON 值与方法专用取值：任意值的字节上限、存储键、文本与高度。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolBridgeValidatorValue")
struct ToolBridgeValidatorValueTests {
  typealias Validator = ToolBridgeValidator

  /// 执行并返回抛出的 `ToolBridgeError`；没有抛出时返回 nil。
  private func failure(_ body: () throws -> Void) -> ToolBridgeError? {
    do {
      try body()
      return nil
    } catch {
      return error as? ToolBridgeError
    }
  }

  /// 任意 JSON 值：`null` 是合法值（只有缺失才算没有）；编码后的字节数不能超过上限。
  @Test func valueAcceptsNullAndLimitsEncodedBytes() throws {
    let params: [String: JSONValue] = ["s": "abc", "n": nil, "o": ["a": 1]]
    #expect(try Validator.value(params, "n", maximumBytes: 10) == .null)
    #expect(try Validator.value(params, "s", maximumBytes: 5) == "abc")
    #expect(try Validator.value(params, "o", maximumBytes: 7) == ["a": 1])
    #expect(failure { _ = try Validator.value(params, "s", maximumBytes: 4) } == .payloadTooLarge)
    #expect(failure { _ = try Validator.value(params, "o", maximumBytes: 6) } == .payloadTooLarge)
    #expect(failure { _ = try Validator.value(params, "missing", maximumBytes: 9) } == .invalidParams("missing"))
    #expect(try Validator.value(params, "missing", maximumBytes: 9, required: false) == nil)
    // 无法编码成 JSON 的值（NaN）报 invalid_params，而不是被当成零字节放行。
    #expect(failure { _ = try Validator.value(["n": .number(.nan)], "n", maximumBytes: 99) } == .invalidParams("value"))
  }

  /// 编码后的字节数（紧凑 JSON，非 ASCII 不转义）。
  @Test func encodedByteCountMatchesCompactJSON() throws {
    let cases: [(JSONValue, Int)] = [
      (.string("abc"), 5), (.string("你好"), 8), (.null, 4), (.bool(true), 4), (.bool(false), 5),
      (.number(12), 2), (.number(-3), 2), (.number(1.5), 3), ([1, 2], 5), ([], 2), ([:], 2), (["a": 1], 7),
    ]
    for (value, expected) in cases {
      #expect(try Validator.encodedByteCount(value) == expected, "\(value)")
    }
  }

  /// NaN 与无穷大无法编码成 JSON。
  @Test(arguments: [JSONValue.number(.nan), .number(.infinity), .number(-.infinity), ["a": .number(.nan)]])
  func encodedByteCountRejectsNonFiniteNumbers(value: JSONValue) {
    #expect(failure { _ = try Validator.encodedByteCount(value) } == .invalidParams("value"))
  }

  // MARK: 方法专用

  /// 存储键：非空且 ≤ 128 字节（按 UTF-8）；缺失、空串、null、非字符串都报 `invalid_params("key")`。
  @Test func storageKeyMustBeNonEmptyAndShort() throws {
    #expect(try Validator.storageKey(["key": "k"]) == "k")
    #expect(try Validator.storageKey(["key": .string(String(repeating: "a", count: 128))]).utf8.count == 128)
    // 42 个汉字 126 字节 + 2 个字母正好 128 字节。
    #expect(try Validator.storageKey(["key": .string(String(repeating: "你", count: 42) + "ab")]).utf8.count == 128)
    for params: [String: JSONValue] in [[:], ["key": ""], ["key": nil], ["key": 1], ["key": ["a"]]] {
      #expect(failure { _ = try Validator.storageKey(params) } == .invalidParams("key"), "\(params)")
    }
    #expect(failure { _ = try Validator.storageKey(["key": .string(String(repeating: "a", count: 129))]) } == .payloadTooLarge)
    #expect(failure { _ = try Validator.storageKey(["key": .string(String(repeating: "你", count: 43))]) } == .payloadTooLarge)
  }

  /// 文本：≤ 1 MiB，空串合法；超出报 `payload_too_large`；缺失或类型不对报 `invalid_params("text")`。
  @Test func textLimitsToOneMiB() throws {
    let limit = ToolBridgeProtocol.maximumTextBytes
    #expect(try Validator.text(["text": ""]) == "")
    #expect(try Validator.text(["text": "你好\n"]) == "你好\n")
    #expect(try Validator.text(["text": .string(String(repeating: "a", count: limit))]).utf8.count == limit)
    #expect(failure { _ = try Validator.text(["text": .string(String(repeating: "a", count: limit + 1))]) } == .payloadTooLarge)
    for params: [String: JSONValue] in [[:], ["text": nil], ["text": 1], ["text": ["a"]]] {
      #expect(failure { _ = try Validator.text(params) } == .invalidParams("text"), "\(params)")
    }
  }

  /// 高度：四舍五入后收进 120–800；页面算出的小数或越界值不报错。
  @Test(arguments: [
    (JSONValue.number(300), 300), (.number(300.4), 300), (.number(300.5), 301), (.number(799.6), 800), (.number(800), 800),
    (.number(801), 800), (.number(1e9), 800), (.number(120), 120), (.number(119.5), 120), (.number(119.4), 120),
    (.number(0), 120), (.number(-50), 120), (.number(-1e9), 120),
  ])
  func heightRoundsAndClamps(value: JSONValue, expected: Int) throws {
    #expect(try Validator.height(["height": value]) == expected)
    #expect(ToolUIConfig.heightRange == 120...800)
  }

  /// 高度不是有限数字时报 `invalid_params("height")`：缺失、null、字符串、布尔、NaN、无穷大。
  @Test(arguments: [JSONValue.string("300"), .null, .bool(true), .array([300]), .number(.nan), .number(.infinity), .number(-.infinity)])
  func heightRejectsNonNumbers(value: JSONValue) {
    #expect(failure { _ = try Validator.height(["height": value]) } == .invalidParams("height"))
    #expect(failure { _ = try Validator.height([:]) } == .invalidParams("height"))
  }
}
