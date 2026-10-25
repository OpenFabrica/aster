// 独立保存词频、整行历史、自动探测、目录学习和显式规格覆盖。
import Foundation

/// 补全学习的持久化值。字段独立，清除整行历史不会顺带清除词频。
public struct CompletionLearningState: Codable, Equatable, Sendable {
  public struct Token: Codable, Equatable, Sendable {
    /// command_history 的 context：空串、命令子命令路径或相对命令的目录上下文。
    public var command: String
    public var token: String
    public var count: Int
    /// 最近一次记录时的频率分；查询时再按 lastUsed 计算时间衰减。
    public var score: Double
    public var lastUsed: Date

    public init(command: String, token: String, count: Int = 1, score: Double? = nil, lastUsed: Date) {
      self.command = command
      self.token = token
      self.count = count
      self.score = score ?? Double(count)
      self.lastUsed = CompletionLearningState.wholeSecond(lastUsed)
    }

    private enum CodingKeys: String, CodingKey { case command, token, count, score, lastUsed }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      command = try values.decode(String.self, forKey: .command)
      token = try values.decode(String.self, forKey: .token)
      count = try values.decode(Int.self, forKey: .count)
      score = try values.decodeIfPresent(Double.self, forKey: .score) ?? Double(count)
      lastUsed = CompletionLearningState.wholeSecond(try values.decode(Date.self, forKey: .lastUsed))
    }
  }

  public struct Line: Codable, Equatable, Sendable {
    public var command: String
    public var directory: String
    public var count: Int
    public var score: Double
    public var lastUsed: Date

    public init(command: String, directory: String, count: Int = 1, score: Double? = nil, lastUsed: Date) {
      self.command = command
      self.directory = directory
      self.count = count
      self.score = score ?? Double(count)
      self.lastUsed = CompletionLearningState.wholeSecond(lastUsed)
    }

    private enum CodingKeys: String, CodingKey { case command, directory, count, score, lastUsed }

    public init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      command = try values.decode(String.self, forKey: .command)
      directory = try values.decode(String.self, forKey: .directory)
      count = try values.decode(Int.self, forKey: .count)
      score = try values.decodeIfPresent(Double.self, forKey: .score) ?? Double(count)
      lastUsed = CompletionLearningState.wholeSecond(try values.decode(Date.self, forKey: .lastUsed))
    }
  }

  public var schemaVersion = 2
  public var history: [Token] = []
  public var fullLines: [Line] = []
  public var helpProbe: [AutocompleteCommandSpec] = []
  public var learnedFolder: [Line] = []
  public var learnedSpecs: [AutocompleteCommandSpec] = []

  public init() {}

  /// 原版只保存非负整 Unix 秒；同一秒内的记录不因亚秒时间产生先后或衰减差异。
  public static func wholeSecond(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(max(0, date.timeIntervalSince1970)))
  }

  /// Otty 1.6.2 先将两次时间各取整秒，再按小时衰减；未来时间不衰减，上限 720 小时。
  public static func frecency(score: Double, lastUsed: Date, now: Date) -> Double {
    let elapsed = wholeSecond(now).timeIntervalSince(wholeSecond(lastUsed))
    return score * pow(0.95, min(720, max(0, elapsed / 3_600)))
  }

  /// 仅删除选中范围；调用方负责持久化成功后才发布新状态。
  public mutating func clear(_ selection: AutocompleteClearSelection) {
    if selection.contains(.history) { history.removeAll() }
    if selection.contains(.fullLines) { fullLines.removeAll() }
    if selection.contains(.helpProbe) { helpProbe.removeAll() }
    if selection.contains(.learnedFolder) { learnedFolder.removeAll() }
    if selection.contains(.learnedSpecs) { learnedSpecs.removeAll() }
  }
}
