// 插件正则的共用工具：编译缓存、带时间预算的匹配，以及「会不会产生空匹配」的探测。
import Foundation
import os

enum ToolRegex {
  /// 单次匹配的时间预算。插件正则可能写出灾难性回溯（如 `(a+)+$`），超时按「没命中」处理，不能卡住启动器。
  static let matchBudget: Duration = .milliseconds(50)
  static let maximumCachedExpressions = 1_024
  /// NSRegularExpression 不可变、可跨线程共享；无法编译的模式缓存为 nil，避免每次重新编译。
  private static let cache = OSAllocatedUnfairLock(initialState: [String: NSRegularExpression?]())

  /// 取编译好的正则；无法编译时为 nil。清单校验已经报告过编译错误，匹配阶段只把它当作永远不命中。
  static func compiled(_ pattern: String) -> NSRegularExpression? {
    if let cached = cache.withLock({ $0[pattern] }) { return cached }
    let expression: NSRegularExpression?
    do {
      expression = try NSRegularExpression(pattern: pattern)
    } catch {
      expression = nil
    }
    cache.withLock { storage in
      // 模式来自已安装插件，数量有限；超过上限说明在反复换模式，整表清空即可，不做 LRU。
      if storage.count >= maximumCachedExpressions { storage.removeAll(keepingCapacity: true) }
      storage[pattern] = expression
    }
    return expression
  }

  /// 一次匹配的结果；超时与没命中分开，方便调用方决定保守策略。
  enum Outcome: Equatable {
    case matched
    case notMatched
    case timedOut
  }

  /// 在时间预算内找第一个匹配。`allowsEmptyMatch` 为 false 时跳过零长度匹配。
  /// 用 `.reportProgress` 是因为 ICU 会在长时间回溯中周期性回调，借此按截止时间中止；普通正则几乎没有额外开销。
  static func firstMatch(
    _ expression: NSRegularExpression,
    in text: String,
    allowsEmptyMatch: Bool,
    budget: Duration = matchBudget
  ) -> Outcome {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: budget)
    var outcome = Outcome.notMatched
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) {
      result, _, stop in
      if let result, allowsEmptyMatch || result.range.length > 0 {
        outcome = .matched
        stop.pointee = true
      } else if clock.now >= deadline {
        outcome = .timedOut
        stop.pointee = true
      }
    }
    return outcome
  }

  /// 探针文本：覆盖空串、空白、字母、数字、标点、换行、中文与带变音字母。
  private static let emptyMatchProbes = [
    "", " ", "a", "Z", "0", "_", "-", ".", "/", "\n", "a b", "ab12", "中文", "é", "{}", "[]", "=", "%",
  ]

  /// 正则会不会产生零长度匹配。
  /// ICU 没有可用的「可空」分析接口，这里对一组探针找出全部匹配，出现零长度匹配就算可空。这能抓住
  /// `a*`、`x?`、`^`、`\b`、`(?=.)` 这类会命中任意输入的写法；只在特定内容前才产生空匹配的写法
  /// （如 `(?=foo)`）可能漏网，但它们不会命中任意输入，不违背「不能匹配空串」想防的问题。
  static func canMatchEmpty(_ expression: NSRegularExpression) -> Bool {
    emptyMatchProbes.contains { probe in
      var found = false
      expression.enumerateMatches(in: probe, range: NSRange(probe.startIndex..., in: probe)) { result, _, stop in
        if let result, result.range.length == 0 {
          found = true
          stop.pointee = true
        }
      }
      return found
    }
  }
}
