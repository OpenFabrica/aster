// 原生补全按整 Unix 秒保存和比较学习时间。
import Foundation
import Testing
@testable import AsterCore

@Test("学习记录构造与解码丢弃亚秒精度，衰减先分别取整秒")
func completionHistoryUsesWholeUnixSeconds() throws {
  let start = Date(timeIntervalSince1970: 1_000.1)
  let later = Date(timeIntervalSince1970: 1_000.9)
  var token = CompletionLearningState.Token(command: "tool", token: "value", lastUsed: start)
  var line = CompletionLearningState.Line(command: "tool value", directory: "/a", lastUsed: later)
  #expect(token.lastUsed == line.lastUsed)
  #expect(token.lastUsed.timeIntervalSince1970 == 1_000)
  // 可变值也必须在解码边界归一化，避免恢复后用亚秒改变排序。
  token.lastUsed = later
  line.lastUsed = start
  let decodedToken = try JSONDecoder().decode(CompletionLearningState.Token.self,
    from: JSONEncoder().encode(token))
  let decodedLine = try JSONDecoder().decode(CompletionLearningState.Line.self,
    from: JSONEncoder().encode(line))
  #expect(decodedToken.lastUsed == decodedLine.lastUsed)
  #expect(decodedToken.lastUsed.timeIntervalSince1970 == 1_000)
  #expect(CompletionLearningState.frecency(score: 2, lastUsed: start, now: later) == 2)
  let hourLater = Date(timeIntervalSince1970: 4_600.9)
  #expect(abs(CompletionLearningState.frecency(score: 2, lastUsed: start, now: hourLater) - 1.9) < 0.000_001)
}
