// 一个 agent 终端里「当前命令」的状态跟踪：每次读屏后推进一步，给出完成 / 等输入 / 恢复事件。
// 纯值类型：读屏、计时与界面都由 App 层驱动，这里只做判断，便于单测覆盖各种时序。
import Foundation

/// 当前命令与最近完成命令的跟踪器。
public struct AgentHostCommandTracker: Sendable {
  /// 正在运行的命令。
  public struct Running: Equatable, Sendable {
    public var id: String
    public var nonce: String
    public var command: String
    public var startedAt: Date
    /// 第几次进入「等输入」；`host.wait` 只对等待开始之后的新一轮提前返回。
    public var needsInputEpisode = 0
    /// 当前等输入的提示行；屏幕再变化就清空。
    public var prompt: String?
    var lastScreen: String?
    var lastChangeAt: Date
    var interruptRequestedAt: Date?
  }

  /// 已结束的命令。输出已按存储上限截断过一次。
  public struct Finished: Equatable, Sendable {
    public var id: String
    public var status: HostExecStatus
    public var exitCode: Int?
    public var output: String
    public var outputTruncated: Bool
    public var durationMs: Int
  }

  /// 一步观察的结果。
  public enum Event: Equatable, Sendable {
    case finished(Finished)
    case needsInput(prompt: String)
    /// 等输入之后屏幕又变了（用户已回答）。
    case resumed
  }

  /// 保留最近完成命令的条数，供迟到的 `host.wait` 取结果。
  public static let finishedHistoryLimit = 16
  /// 存储时的输出上限，等于协议允许的最大 `max_output_bytes`。
  public static let storedOutputLimit = AgentHostLimits.maximumOutputBytesLimit

  public private(set) var running: Running?
  public private(set) var finished: [Finished] = []
  public var needsInputQuiet: TimeInterval
  public var interruptGrace: TimeInterval

  public init(needsInputQuiet: TimeInterval = 2, interruptGrace: TimeInterval = 1.5) {
    self.needsInputQuiet = needsInputQuiet
    self.interruptGrace = interruptGrace
  }

  /// 开始跟踪一条刚敲进去的命令。调用方保证此前没有运行中的命令。
  public mutating func start(id: String, nonce: String, command: String, at now: Date) {
    running = Running(id: id, nonce: nonce, command: command, startedAt: now, lastChangeAt: now)
  }

  /// 已完成命令的结果。
  public func finishedCommand(_ id: String) -> Finished? {
    finished.last { $0.id == id }
  }

  /// 记下中断请求；宽限期内仍等结束标记（命令可能自己处理了 SIGINT）。
  public mutating func requestInterrupt(at now: Date) {
    running?.interruptRequestedAt = now
  }

  /// 推进一步：`screen` 是活动屏幕；`scrollback` 在需要完整输出时才调用一次。
  public mutating func observe(screen: String, now: Date, scrollback: () -> String?) -> Event? {
    guard var current = running else { return nil }
    let parsed = AgentHostCommandFraming.parse(screen, nonce: current.nonce)
    if case .completed(let code, let output, let beginSeen) = parsed {
      // 开始标记滚出活动屏幕时，从回滚里再找一次，尽量拿到完整输出。
      if !beginSeen, let full = scrollback(),
        case .completed(_, let fullOutput, let fullBegin) = AgentHostCommandFraming.parse(full, nonce: current.nonce)
      {
        return .finished(finish(.completed, exitCode: code, output: fullOutput, truncated: !fullBegin, now: now))
      }
      return .finished(finish(.completed, exitCode: code, output: output, truncated: !beginSeen, now: now))
    }
    if let requested = current.interruptRequestedAt, now.timeIntervalSince(requested) >= interruptGrace {
      return .finished(finish(.interrupted, exitCode: nil, output: partialOutput(scrollback()), truncated: false, now: now))
    }
    if screen != current.lastScreen {
      current.lastScreen = screen
      current.lastChangeAt = now
      let wasWaiting = current.prompt != nil
      current.prompt = nil
      running = current
      return wasWaiting ? .resumed : nil
    }
    // 只有开始标记已出现（命令真的在跑）、屏幕静止够久、最后一行像提示，才算等输入。
    if case .running = parsed, current.prompt == nil,
      now.timeIntervalSince(current.lastChangeAt) >= needsInputQuiet,
      let prompt = AgentHostPromptHeuristics.prompt(in: screen)
    {
      current.prompt = prompt
      current.needsInputEpisode += 1
      running = current
      return .needsInput(prompt: prompt)
    }
    return nil
  }

  /// 终端结束（Shell 退出、连接断开或被关闭）：运行中的命令记为 `ended`。
  public mutating func end(at now: Date, scrollback: String?) -> Finished? {
    guard running != nil else { return nil }
    return finish(.ended, exitCode: nil, output: partialOutput(scrollback), truncated: false, now: now)
  }

  /// 运行中命令到目前为止的输出（开始标记之后的部分）。
  public func partialOutput(_ text: String?) -> String {
    guard let running, let text else { return "" }
    if case .running(let output) = AgentHostCommandFraming.parse(text, nonce: running.nonce) {
      return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }
    return ""
  }

  /// 收尾：清空运行中命令，结果入历史（有上限）。
  private mutating func finish(
    _ status: HostExecStatus, exitCode: Int?, output: String, truncated: Bool, now: Date
  ) -> Finished {
    let startedAt = running?.startedAt ?? now
    let stored = AgentHostCommandFraming.truncate(output, maximumBytes: Self.storedOutputLimit)
    let result = Finished(
      id: running?.id ?? "", status: status, exitCode: exitCode, output: stored.text,
      outputTruncated: truncated || stored.truncated,
      durationMs: max(Int(now.timeIntervalSince(startedAt) * 1_000), 0))
    running = nil
    finished.append(result)
    if finished.count > Self.finishedHistoryLimit { finished.removeFirst(finished.count - Self.finishedHistoryLimit) }
    return result
  }
}
