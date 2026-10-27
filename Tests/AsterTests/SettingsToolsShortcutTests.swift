// 工具面板快捷键：兼容键的默认值与允许取值、与 Quick Terminal 的双向冲突，以及 SettingsViewController 对 tools. 动作的路由。
import Foundation
import Testing

@testable import Aster

// MARK: - 兼容键与快捷键冲突

@Test("工具面板快捷键：兼容键默认 none，只接受三种取值")
@MainActor
func settingsLauncherShortcutCompatibilityKey() throws {
  let preferences = isolatedToolsPreferences()
  let controller = SettingsViewController(preferences: preferences, updateController: nil)
  let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["tools.launcherShortcut"] as? String == "none")
  let tools = try #require(controller.settingsSnapshotForTesting()["tools"] as? [String: Any])
  #expect(tools["launcherShortcut"] as? String == "none")

  for choice in ["optionSpace", "controlOptionSpace", "none"] {
    try controller.applySettingForTesting(key: "tools.launcherShortcut", value: choice)
    #expect(preferences.compatibilityString(forKey: "tools.launcherShortcut", default: "?") == choice)
  }
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "tools.launcherShortcut", value: "commandSpace")
  }
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "tools.launcherShortcut", value: true)
  }
  #expect(preferences.compatibilityString(forKey: "tools.launcherShortcut", default: "?") == "none")
}

@Test("工具面板与 Quick Terminal 不能选同一组合，两个方向都拒绝")
@MainActor
func settingsShortcutConflictIsRejectedBothWays() throws {
  let preferences = isolatedToolsPreferences()
  let controller = SettingsViewController(preferences: preferences, updateController: nil)

  try controller.applySettingForTesting(key: "quickTerminal.shortcut", value: "controlOptionSpace")
  #expect(throws: SettingsShortcutConflict.usedByQuickTerminal) {
    try controller.applySettingForTesting(key: "tools.launcherShortcut", value: "controlOptionSpace")
  }
  #expect(preferences.compatibilityString(forKey: "tools.launcherShortcut", default: "none") == "none")

  try controller.applySettingForTesting(key: "quickTerminal.shortcut", value: "controlGrave")
  try controller.applySettingForTesting(key: "tools.launcherShortcut", value: "controlOptionSpace")
  #expect(throws: SettingsShortcutConflict.usedByToolLauncher) {
    try controller.applySettingForTesting(key: "quickTerminal.shortcut", value: "controlOptionSpace")
  }
  #expect(preferences.compatibilityString(forKey: "quickTerminal.shortcut", default: "none") == "controlGrave")

  // 「不启用」不算占用：两边同时为 none 合法。
  try controller.applySettingForTesting(key: "tools.launcherShortcut", value: "none")
  try controller.applySettingForTesting(key: "quickTerminal.shortcut", value: "none")
  #expect(SettingsShortcutConflict.usedByQuickTerminal.errorDescription?.isEmpty == false)
}

@Test("设置页把 tools. 动作交给工具协作者，快照里带 tools 键")
@MainActor
func settingsControllerRoutesToolsActions() throws {
  let preferences = isolatedToolsPreferences()
  let tools = FakeToolCenter()
  tools.pluginSummaries = [toolSummary("com.example.a", name: "A")]
  let (bridge, recorder) = makeToolsBridge(tools, preferences: preferences)
  let controller = SettingsViewController(preferences: preferences, updateController: nil, toolsBridge: bridge)
  controller.applyThemeActionForTesting("tools.openLauncher", payload: [:])
  #expect(recorder.launcherOpened == 1)
  let snapshot = try #require(controller.settingsSnapshotForTesting()["tools"] as? [String: Any])
  #expect((snapshot["plugins"] as? [[String: Any]])?.count == 1)
}
