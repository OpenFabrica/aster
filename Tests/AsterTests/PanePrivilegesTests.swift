import AppKit
import AsterCore
import Foundation
import Testing
@testable import Aster

@MainActor
private final class PrivilegeNotificationRecorder: TerminalNotificationPosting {
  var categories: [TerminalNotificationCategory] = []
  func post(_ notification: TerminalNotification, category: TerminalNotificationCategory,
    configuration: ShellConfiguration, sourceTabIsFocused: Bool
  ) { categories.append(category) }
}

@MainActor
private func privilegePreferences() throws -> (AppPreferences, String, UserDefaults) {
  let name = "PanePrivilegesTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: name))
  defaults.removePersistentDomain(forName: name)
  return (AppPreferences(defaults: defaults), name, defaults)
}

@Test("共享权限同步作用于绑定会话，不改变另一实例或全局配置")
@MainActor
func panePrivilegesSharedScopeAndGlobalIsolation() throws {
  let (preferences, name, defaults) = try privilegePreferences()
  defer { defaults.removePersistentDomain(forName: name) }
  preferences.configuration.shell.terminalBell = true
  let original = preferences.configuration
  let first = TerminalSession(workingDirectory: "/tmp")
  let sibling = TerminalSession(workingDirectory: "/tmp")
  let other = TerminalSession(workingDirectory: "/tmp")
  for session in [first, sibling, other] { session.apply(preferences: preferences) }
  sibling.privilegesState = first.privilegesState
  first.privilegesState.set(.terminalBell, to: false)
  #expect(!first.resolvedPrivileges.terminalBell && !sibling.resolvedPrivileges.terminalBell)
  #expect(other.resolvedPrivileges.terminalBell)
  #expect(preferences.configuration == original)
  preferences.configuration.shell.notifyOnFinish = true
  #expect(first.resolvedPrivileges.notifyOnFinish && sibling.resolvedPrivileges.notifyOnFinish)
}

@Test("权限开关真正约束错误提示音、Bell、普通/监视/应用通知")
@MainActor
func panePrivilegesNotificationAndSoundRuntime() throws {
  let (preferences, name, defaults) = try privilegePreferences()
  defer { defaults.removePersistentDomain(forName: name) }
  preferences.configuration.shell.notifyOnFinish = true
  preferences.configuration.shell.notifyOnError = true
  preferences.configuration.shell.notifyOnWatchFinish = true
  preferences.configuration.shell.soundOnErrorExit = true
  let recorder = PrivilegeNotificationRecorder()
  let session = TerminalSession(workingDirectory: "/tmp", notificationPoster: recorder)
  var sounds = 0
  session.playTerminalSound = { sounds += 1 }
  let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  view.onShellIntegrationEvent?(.commandFinished(exitStatus: 1))
  view.bell(source: view.getTerminal())
  #expect(recorder.categories == [.errorExit])
  #expect(sounds == 2)

  session.privilegesState.muteSound()
  session.privilegesState.muteNotifications()
  view.onShellIntegrationEvent?(.commandStart)
  view.onShellIntegrationEvent?(.commandFinished(exitStatus: 1))
  view.onTerminalProgress?(.finished(exitCode: 0, watched: true))
  view.onTerminalNotification?(TerminalNotification(title: "app", body: "message"))
  view.bell(source: view.getTerminal())
  #expect(recorder.categories == [.errorExit])
  #expect(sounds == 2)

  session.privilegesState.set(.notifyOnFinish, to: true)
  view.onShellIntegrationEvent?(.commandStart)
  view.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(recorder.categories == [.errorExit, .commandFinish])
  session.privilegesState.set(.notificationShellControlled, to: true)
  view.onTerminalNotification?(TerminalNotification(title: "app", body: "message"))
  #expect(recorder.categories.last == .application)
  #expect(preferences.configuration.shell.terminalBell)
}

@Test("Agent徽标与防休眠使用运行期覆盖，通知静音不误清独立Agent通知")
@MainActor
func panePrivilegesAgentRuntime() throws {
  let (preferences, name, defaults) = try privilegePreferences()
  defer { defaults.removePersistentDomain(forName: name) }
  preferences.configuration.agents.screenDetectionEnabled = false
  let recorder = PrivilegeNotificationRecorder()
  let session = TerminalSession(workingDirectory: "/tmp", notificationPoster: recorder)
  let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  view.onAgentTerminalDirective?(.init(provider: .codex, signal: .processing))
  #expect(session.agentActivityBadge == .running(percent: nil))
  session.privilegesState.set(.badgeAgentProcessing, to: false)
  #expect(session.agentActivityBadge == TerminalBadgeState.none)
  session.privilegesState.set(.caffeinateAgentProcessing, to: true)
  #expect(session.shouldPreventSleep)
  session.privilegesState.muteNotifications()
  view.onAgentTerminalDirective?(.init(provider: .codex, signal: .awaitingInput))
  #expect(!session.shouldPreventSleep)
  #expect(session.agentActivityBadge == .awaitingInput)
  session.privilegesState.set(.badgeAgentAwaitingInput, to: false)
  #expect(session.agentActivityBadge == TerminalBadgeState.none)
  view.onAgentTerminalDirective?(.init(provider: .codex, signal: .idle))
  #expect(session.agentActivityBadge == .finished)
  session.privilegesState.set(.badgeAgentTaskComplete, to: false)
  #expect(session.agentActivityBadge == TerminalBadgeState.none)
  #expect(recorder.categories.count == 2)
}

@Test("一次防休眠逐会话结束释放，持续请求只在显式关闭后撤销")
@MainActor
func panePrivilegesCaffeinateLifecycle() {
  let first = TerminalSession(workingDirectory: "/tmp")
  let second = TerminalSession(workingDirectory: "/tmp")
  let shared = first.privilegesState
  second.privilegesState = shared
  shared.setCaffeinateMode(.forThisTask, sessionIDs: [first.id, second.id])
  #expect(first.shouldPreventSleep && second.shouldPreventSleep)
  first.stop(immediately: true)
  #expect(!first.shouldPreventSleep && second.shouldPreventSleep)
  second.stop(immediately: true)
  #expect(shared.caffeinateMode == .off)
  shared.setCaffeinateMode(.forAllTasks)
  #expect(first.shouldPreventSleep)
  shared.taskFinished(sessionID: first.id)
  #expect(first.shouldPreventSleep)
  shared.setCaffeinateMode(.off)
  #expect(!first.shouldPreventSleep)
}

@Test("权限菜单动作就地记录覆盖，普通防休眠交给宿主确认")
@MainActor
func panePrivilegesMenuActions() throws {
  let (preferences, name, defaults) = try privilegePreferences()
  defer { defaults.removePersistentDomain(forName: name) }
  let session = TerminalSession(workingDirectory: "/tmp")
  session.apply(preferences: preferences)
  var confirmations = 0
  let menu = PanePrivilegesMenu.make(session: session, preferences: preferences,
    toggleCaffeinate: { confirmations += 1 })
  let mouse = try #require(menu.items.first { $0.identifier?.rawValue == "allowMouseCapture" })
  #expect(mouse.state == .on)
  _ = try #require(mouse.target as? NSObject).perform(try #require(mouse.action), with: mouse)
  #expect(!session.resolvedPrivileges.allowMouseCapture)
  #expect(session.privilegesState.userOverrides[.allowMouseCapture] == false)
  let caffeinate = try #require(menu.items.first { $0.identifier?.rawValue == "caffeinateTask" })
  _ = try #require(caffeinate.target as? NSObject).perform(try #require(caffeinate.action), with: caffeinate)
  #expect(confirmations == 1)
  #expect(session.privilegesState.caffeinateMode == .off)
  #expect(preferences.configuration.controls.allowMouseReporting)
}
