// 桥接参数取值：必填与可选、类型检查、项数与字节数上限，以及存储键、文本与高度这几个方法专用的取值。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolBridgeValidatorParams")
struct ToolBridgeValidatorParamsTests {
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

  // MARK: 通用取值

  /// 字符串：恰好等于上限可以，超出报 `payload_too_large`（按 UTF-8 字节）；缺失、null、类型不对报 `invalid_params`。
  @Test func stringChecksPresenceTypeAndByteLimit() throws {
    let params: [String: JSONValue] = ["s": "abc", "empty": "", "cjk": "你好", "n": 1, "z": nil]
    #expect(try Validator.string(params, "s", maximumBytes: 3) == "abc")
    #expect(try Validator.string(params, "empty", maximumBytes: 0) == "")
    #expect(try Validator.string(params, "cjk", maximumBytes: 6) == "你好")
    #expect(failure { _ = try Validator.string(params, "s", maximumBytes: 2) } == .payloadTooLarge)
    #expect(failure { _ = try Validator.string(params, "cjk", maximumBytes: 5) } == .payloadTooLarge)
    #expect(failure { _ = try Validator.string(params, "n", maximumBytes: 9, required: false) } == .invalidParams("n"))
    #expect(failure { _ = try Validator.string(params, "missing", maximumBytes: 9) } == .invalidParams("missing"))
    #expect(failure { _ = try Validator.string(params, "z", maximumBytes: 9) } == .invalidParams("z"))
    #expect(try Validator.string(params, "missing", maximumBytes: 9, required: false) == nil)
    #expect(try Validator.string(params, "z", maximumBytes: 9, required: false) == nil)
  }

  /// 整数：只认整数值（`5.0` 可以，`1.5` 不行），给了范围时两端含在内；超出 2^53 或非有限数不行。
  @Test func intAcceptsOnlyIntegralNumbersInRange() throws {
    let valid: [(JSONValue, ClosedRange<Int>?, Int)] = [
      (5, nil, 5), (5.0, nil, 5), (0, nil, 0), (-3, nil, -3), (1e9, nil, 1_000_000_000),
      (1, 1...10, 1), (10, 1...10, 10), (9_007_199_254_740_991, nil, 9_007_199_254_740_991),
    ]
    for (value, range, expected) in valid {
      #expect(try Validator.int(["k": value], "k", range: range) == expected, "\(value)")
    }
    let invalid: [(JSONValue, ClosedRange<Int>?)] = [
      (1.5, nil), ("5", nil), (true, nil), ([1], nil), ([:], nil), (nil, nil),
      (0, 1...10), (11, 1...10), (-1, 1...10), (5.5, 1...10),
      (9_007_199_254_740_992, nil), (1e300, nil), (.number(.nan), nil), (.number(.infinity), nil), (.number(-.infinity), nil),
    ]
    for (value, range) in invalid {
      #expect(failure { _ = try Validator.int(["k": value], "k", range: range) } == .invalidParams("k"), "\(value)")
    }
    #expect(failure { _ = try Validator.int([:], "k") } == .invalidParams("k"))
    #expect(try Validator.int([:], "k", required: false) == nil)
    #expect(try Validator.int(["k": nil], "k", required: false) == nil)
  }

  /// 数字：整数与小数都行；类型不对、缺失、null 与 int 一样处理。
  @Test func doubleAcceptsAnyNumber() throws {
    #expect(try Validator.double(["k": 1.5], "k") == 1.5)
    #expect(try Validator.double(["k": 2], "k") == 2)
    #expect(try Validator.double(["k": -0.25], "k") == -0.25)
    for value: JSONValue in ["1.5", true, [1], [:], nil] {
      #expect(failure { _ = try Validator.double(["k": value], "k") } == .invalidParams("k"), "\(value)")
    }
    #expect(failure { _ = try Validator.double([:], "k") } == .invalidParams("k"))
    #expect(try Validator.double(["k": nil], "k", required: false) == nil)
  }

  /// 布尔：默认可选；字符串 `"true"` 与数字 1 不算布尔；必填时缺失报错。
  @Test func boolIsOptionalByDefaultAndStrict() throws {
    #expect(try Validator.bool(["k": true], "k") == true)
    #expect(try Validator.bool(["k": false], "k") == false)
    #expect(try Validator.bool([:], "k") == nil)
    #expect(try Validator.bool(["k": nil], "k") == nil)
    for value: JSONValue in ["true", 1, 0, [:], []] {
      #expect(failure { _ = try Validator.bool(["k": value], "k") } == .invalidParams("k"), "\(value)")
    }
    #expect(failure { _ = try Validator.bool([:], "k", required: true) } == .invalidParams("k"))
  }

  /// 对象：必须是对象；必填缺失报错，可选缺失为 nil。
  @Test func objectRequiresAnObject() throws {
    #expect(try Validator.object(["k": ["a": 1]], "k") == ["a": 1])
    #expect(try Validator.object(["k": [:]], "k") == [:])
    for value: JSONValue in [[1], "x", 1, true, nil] {
      #expect(failure { _ = try Validator.object(["k": value], "k") } == .invalidParams("k"), "\(value)")
    }
    #expect(try Validator.object([:], "k", required: false) == nil)
  }

  /// 数组：项数等于上限可以；超过上限报 `invalid_params`（不是 payload_too_large）；不是数组报错。
  @Test func arrayLimitsItemCount() throws {
    let params: [String: JSONValue] = ["k": [1, 2, 3], "empty": [], "obj": [:]]
    #expect(try Validator.array(params, "k", maximumCount: 3) == [1, 2, 3])
    #expect(try Validator.array(params, "empty", maximumCount: 0) == [])
    #expect(failure { _ = try Validator.array(params, "k", maximumCount: 2) } == .invalidParams("k"))
    #expect(failure { _ = try Validator.array(params, "obj", maximumCount: 9) } == .invalidParams("obj"))
    #expect(failure { _ = try Validator.array(params, "missing", maximumCount: 9) } == .invalidParams("missing"))
    #expect(try Validator.array(params, "missing", maximumCount: 9, required: false) == nil)
  }

  /// 字符串数组：项数超限报 `invalid_params`，元素不是字符串报 `invalid_params`，单项字节超限报 `payload_too_large`。
  @Test func stringArrayChecksCountElementTypeAndBytes() throws {
    let params: [String: JSONValue] = ["k": ["ab", "你"], "mixed": ["a", 1], "empty": []]
    #expect(try Validator.stringArray(params, "k", maximumCount: 2, maximumBytesEach: 3) == ["ab", "你"])
    #expect(try Validator.stringArray(params, "empty", maximumCount: 0, maximumBytesEach: 0) == [])
    #expect(failure { _ = try Validator.stringArray(params, "k", maximumCount: 1, maximumBytesEach: 9) } == .invalidParams("k"))
    #expect(failure { _ = try Validator.stringArray(params, "k", maximumCount: 2, maximumBytesEach: 2) } == .payloadTooLarge)
    #expect(failure { _ = try Validator.stringArray(params, "mixed", maximumCount: 9, maximumBytesEach: 9) } == .invalidParams("mixed"))
    #expect(try Validator.stringArray(params, "missing", maximumCount: 9, maximumBytesEach: 9, required: false) == nil)
  }

  /// 字符串字典：项数超限与值不是字符串报 `invalid_params`，键或值的字节超限报 `payload_too_large`。
  @Test func stringDictionaryChecksCountTypesAndBytes() throws {
    let params: [String: JSONValue] = ["k": ["a": "1", "bb": "22"], "bad": ["a": 1], "empty": [:], "list": []]
    #expect(try Validator.stringDictionary(params, "k", maximumCount: 2, maximumBytesEach: 2) == ["a": "1", "bb": "22"])
    #expect(try Validator.stringDictionary(params, "empty", maximumCount: 0, maximumBytesEach: 0) == [:])
    #expect(failure { _ = try Validator.stringDictionary(params, "k", maximumCount: 1, maximumBytesEach: 9) } == .invalidParams("k"))
    #expect(failure { _ = try Validator.stringDictionary(params, "bad", maximumCount: 9, maximumBytesEach: 9) } == .invalidParams("bad"))
    #expect(failure { _ = try Validator.stringDictionary(params, "list", maximumCount: 9, maximumBytesEach: 9) } == .invalidParams("list"))
    // 键 "bb" 是 2 字节，值 "22" 也是 2 字节：任何一边超过 1 字节都超限。
    #expect(failure { _ = try Validator.stringDictionary(params, "k", maximumCount: 9, maximumBytesEach: 1) } == .payloadTooLarge)
    let longKey: [String: JSONValue] = ["k": ["abc": "x"]]
    #expect(failure { _ = try Validator.stringDictionary(longKey, "k", maximumCount: 9, maximumBytesEach: 2) } == .payloadTooLarge)
  }
}
