import Testing
@testable import AsterCore

@Test("未覆盖权限跟随全局，显式覆盖不被后续全局值覆盖")
func panePrivilegesInheritUntilOverridden() {
  var configuration = AsterConfiguration()
  configuration.shell.terminalBell = true
  configuration.shell.notifyOnFinish = false
  var privileges = PanePrivileges()
  #expect(privileges.resolved(in: configuration).terminalBell)
  privileges.set(.terminalBell, to: false)
  configuration.shell.terminalBell = false
  configuration.shell.notifyOnFinish = true
  #expect(!privileges.resolved(in: configuration).terminalBell)
  #expect(privileges.resolved(in: configuration).notifyOnFinish)
  configuration.shell.terminalBell = true
  #expect(!privileges.resolved(in: configuration).terminalBell)
  #expect(privileges.userOverrides == [.terminalBell: false])
}

@Test("静音只清本组字段，重复静音不恢复已关闭权限")
func panePrivilegesMuteGroupsAreExplicitAndIdempotent() {
  var configuration = AsterConfiguration()
  configuration.shell.soundOnErrorExit = true
  configuration.shell.notifyOnFinish = true
  var privileges = PanePrivileges()
  privileges.muteSound()
  privileges.muteSound()
  var values = privileges.resolved(in: configuration)
  #expect(!values.soundOnErrorExit && !values.terminalBell)
  #expect(values.notifyOnFinish && values.allowMouseCapture)
  #expect(privileges.userOverrides.count == 2)
  privileges.muteNotifications()
  privileges.muteNotifications()
  values = privileges.resolved(in: configuration)
  #expect(!values.notifyOnFinish && !values.notifyOnError && !values.notifyOnWatchFinish
    && !values.notificationShellControlled)
  #expect(values.badgeAgentProcessing && values.allowMouseCapture)
  #expect(privileges.userOverrides.count == 6)
  #expect(configuration.agents.notifyTaskComplete)
}
