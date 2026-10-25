// Tab 运行期权限覆盖：未覆盖字段实时继承全局配置，不参与持久化。
import Foundation

public struct PanePrivileges: Equatable, Sendable {
  public enum Field: String, CaseIterable, Hashable, Sendable {
    case soundOnErrorExit, terminalBell
    case notifyOnFinish, notifyOnError, notifyOnWatchFinish, notificationShellControlled
    case badgeCommandFinish, badgeCommandFailure
    case badgeAgentProcessing, badgeAgentTaskComplete, badgeAgentAwaitingInput
    case caffeinateAgentProcessing, allowMouseCapture
  }

  public struct Values: Equatable, Sendable {
    public let soundOnErrorExit: Bool
    public let terminalBell: Bool
    public let notifyOnFinish: Bool
    public let notifyOnError: Bool
    public let notifyOnWatchFinish: Bool
    public let notificationShellControlled: Bool
    public let badgeCommandFinish: Bool
    public let badgeCommandFailure: Bool
    public let badgeAgentProcessing: Bool
    public let badgeAgentTaskComplete: Bool
    public let badgeAgentAwaitingInput: Bool
    public let caffeinateAgentProcessing: Bool
    public let allowMouseCapture: Bool
  }

  public private(set) var userOverrides: [Field: Bool] = [:]
  public init() {}

  public mutating func set(_ field: Field, to value: Bool) { userOverrides[field] = value }

  public mutating func muteSound() {
    set(.soundOnErrorExit, to: false)
    set(.terminalBell, to: false)
  }

  public mutating func muteNotifications() {
    let fields: [Field] = [.notifyOnFinish, .notifyOnError, .notifyOnWatchFinish, .notificationShellControlled]
    for field in fields {
      set(field, to: false)
    }
  }

  public func value(_ field: Field, inheriting configuration: AsterConfiguration) -> Bool {
    if let value = userOverrides[field] { return value }
    let shell = configuration.shell
    let agent = configuration.agents
    return switch field {
    case .soundOnErrorExit: shell.resolvedSoundOnErrorExit
    case .terminalBell: shell.terminalBell
    case .notifyOnFinish: shell.notifyOnFinish
    case .notifyOnError: shell.notifyOnError
    case .notifyOnWatchFinish: shell.resolvedNotifyOnWatchFinish
    case .notificationShellControlled: shell.resolvedNotificationShellControlled
    case .badgeCommandFinish: shell.resolvedBadgeCommandFinish
    case .badgeCommandFailure: shell.resolvedBadgeCommandFailure
    case .badgeAgentProcessing: agent.badgeProcessing
    case .badgeAgentTaskComplete: agent.badgeTaskComplete
    case .badgeAgentAwaitingInput: agent.badgeAwaitingInput
    case .caffeinateAgentProcessing: agent.preventSleepWhileProcessing
    case .allowMouseCapture: configuration.controls.allowMouseReporting
    }
  }

  public func resolved(in configuration: AsterConfiguration) -> Values {
    Values(
      soundOnErrorExit: value(.soundOnErrorExit, inheriting: configuration),
      terminalBell: value(.terminalBell, inheriting: configuration),
      notifyOnFinish: value(.notifyOnFinish, inheriting: configuration),
      notifyOnError: value(.notifyOnError, inheriting: configuration),
      notifyOnWatchFinish: value(.notifyOnWatchFinish, inheriting: configuration),
      notificationShellControlled: value(.notificationShellControlled, inheriting: configuration),
      badgeCommandFinish: value(.badgeCommandFinish, inheriting: configuration),
      badgeCommandFailure: value(.badgeCommandFailure, inheriting: configuration),
      badgeAgentProcessing: value(.badgeAgentProcessing, inheriting: configuration),
      badgeAgentTaskComplete: value(.badgeAgentTaskComplete, inheriting: configuration),
      badgeAgentAwaitingInput: value(.badgeAgentAwaitingInput, inheriting: configuration),
      caffeinateAgentProcessing: value(.caffeinateAgentProcessing, inheriting: configuration),
      allowMouseCapture: value(.allowMouseCapture, inheriting: configuration))
  }
}
