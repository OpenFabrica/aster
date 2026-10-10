// 没有规格的命令是否接受路径参数，按实际用法学习（对应 Otty 的 argument_paths 表）。
import Foundation

/// 记录每个无规格命令的参数习惯：连续两次只给普通单词就不再枚举文件；一旦真的
/// 传了路径立即恢复。有规格的命令以规格为准，不查这张表。
public struct AutocompletePathHabits: Codable, Equatable, Sendable {
  /// 连续多少次纯单词参数后判定「不接受路径」。
  public static let wordStreakThreshold = 2
  public static let capacity = 2_000

  /// 单个命令的习惯。`takesPaths == nil` 表示还没见过足够证据。
  public struct Habit: Codable, Equatable, Sendable {
    public var wordStreak: Int
    public var takesPaths: Bool?
    /// 最近一次更新的 Unix 时间，只用于容量淘汰。
    public var updatedAt: Double
  }

  public private(set) var habits: [String: Habit] = [:]

  public init() {}

  /// 用一条已执行成功的命令更新习惯。`pathProbe` 判断某个参数在当前目录下是否真实存在。
  /// 选项与选项值不算参数；没有位置参数的命令不改变任何结论。
  public mutating func record(command: String, pathProbe: (String) -> Bool, at date: Date = Date()) {
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard let executable = tokens.first, AutocompleteLearnTarget.isBareBinaryName(executable) else { return }
    let arguments = tokens.dropFirst().filter { !$0.hasPrefix("-") }
    guard !arguments.isEmpty else { return }
    var habit = habits[executable] ?? Habit(wordStreak: 0, takesPaths: nil, updatedAt: 0)
    if arguments.contains(where: { Self.looksLikePath($0) || pathProbe($0) }) {
      habit.takesPaths = true
      habit.wordStreak = 0
    } else {
      habit.wordStreak = min(habit.wordStreak + 1, Self.wordStreakThreshold)
      if habit.wordStreak >= Self.wordStreakThreshold { habit.takesPaths = false }
    }
    habit.updatedAt = date.timeIntervalSince1970
    habits[executable] = habit
    if habits.count > Self.capacity { evictOldest() }
  }

  /// 当前 token 位置是否应该列出文件。用户明确在打路径（`./`、`../`、`~/`、`/`、含 `/`）
  /// 时永远列；否则只有学到「不接受路径」时才不列，没有证据时沿用既有行为。
  public func shouldEnumerate(command: String, currentToken: String) -> Bool {
    if Self.looksLikePath(currentToken) { return true }
    return habits[command]?.takesPaths != false
  }

  /// 反序列化校验：容量、计数与时间都要合理，否则整张表作废重学。
  public func validated() -> AutocompletePathHabits? {
    guard habits.count <= Self.capacity,
      habits.allSatisfy({ key, habit in
        AutocompleteLearnTarget.isBareBinaryName(key)
          && (0...Self.wordStreakThreshold).contains(habit.wordStreak)
          && habit.updatedAt.isFinite && habit.updatedAt >= 0
      })
    else { return nil }
    return self
  }

  /// 字面上就是路径的参数：以 `/`、`./`、`../`、`~` 开头，或中间带 `/`，或是 `.`/`..`。
  static func looksLikePath(_ value: String) -> Bool {
    value == "." || value == ".." || value.hasPrefix("~") || value.hasPrefix("/")
      || value.hasPrefix("./") || value.hasPrefix("../") || value.contains("/")
  }

  /// 超过容量时丢掉最久没更新的四分之一，避免每次多一条就淘汰一条。
  private mutating func evictOldest() {
    let ordered = habits.sorted { $0.value.updatedAt < $1.value.updatedAt }
    for (key, _) in ordered.prefix(max(1, Self.capacity / 4)) { habits.removeValue(forKey: key) }
  }
}
