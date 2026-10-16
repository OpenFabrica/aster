// 设置页「Shell」里的 SSH 引擎选项：`shell.sshEngine` 经设置桥读写，非法值被拒绝。
import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Test("shell.sshEngine 经设置桥读写，非法值被拒绝")
@MainActor
func settingsSSHEngineRoundTrips() throws {
  let suite = "SettingsSSHEngine.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  var values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["shell.sshEngine"] as? String == "native")
  try controller.applySettingForTesting(key: "shell.sshEngine", value: "openssh")
  #expect(preferences.configuration.shell.resolvedSSHEngine == .openssh)
  values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["shell.sshEngine"] as? String == "openssh")
  #expect(throws: (any Error).self) { try controller.applySettingForTesting(key: "shell.sshEngine", value: "putty") }
  #expect(preferences.configuration.shell.resolvedSSHEngine == .openssh)
}
