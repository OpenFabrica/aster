// 设置页「工具」分类测试共用的替身与辅助函数：假工具中心、回调记录、隔离偏好、建桥与发动作。
import AppKit
import Combine
import Foundation

@testable import Aster
@testable import AsterCore

// MARK: - 测试替身

/// 假工具中心：记录调用，结果可配置。setEnabled / removeDevelopmentFolder 像真实实现一样同步发出 changes。
@MainActor
final class FakeToolCenter: ToolManaging {
  var pluginSummaries: [ToolPluginSummary] = []
  var pluginIssues: [ToolPluginIssue] = []
  var pluginsDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AsterToolsSettings-\(UUID().uuidString)/Plugins", isDirectory: true)
  var developmentFolders: [String] = []
  let subject = PassthroughSubject<Void, Never>()
  var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

  var reloadCount = 0
  var enabledCalls: [(id: String, enabled: Bool)] = []
  var approveCalls: [(id: String, window: NSWindow?)] = []
  var approveResult = true
  var installedFolders: [URL] = []
  var developmentAdded: [URL] = []
  var addResult: Result<String, ToolCenterError> = .success("com.example.new")
  var removedFolders: [String] = []
  var uninstalled: [String] = []
  var uninstallError: ToolCenterError?

  func reload() { reloadCount += 1 }
  func setEnabled(_ enabled: Bool, pluginID: String) {
    enabledCalls.append((pluginID, enabled))
    subject.send()
  }
  func approve(pluginID: String, window: NSWindow?) async -> Bool {
    approveCalls.append((pluginID, window))
    return approveResult
  }
  func installPlugin(from folder: URL, window: NSWindow?) async throws -> String {
    installedFolders.append(folder)
    return try addResult.get()
  }
  func addDevelopmentFolder(_ folder: URL, window: NSWindow?) async throws -> String {
    developmentAdded.append(folder)
    return try addResult.get()
  }
  func removeDevelopmentFolder(_ path: String) {
    removedFolders.append(path)
    subject.send()
  }
  var viewEnabledCalls: [(id: String, view: String, enabled: Bool)] = []
  var viewSlotCalls: [(id: String, view: String, slot: ToolViewSlot?)] = []
  func setViewEnabled(_ enabled: Bool, pluginID: String, viewID: String) {
    viewEnabledCalls.append((pluginID, viewID, enabled))
    subject.send()
  }
  func setViewSlot(_ slot: ToolViewSlot?, pluginID: String, viewID: String) {
    viewSlotCalls.append((pluginID, viewID, slot))
    subject.send()
  }
  func uninstall(pluginID: String) async throws {
    uninstalled.append(pluginID)
    if let uninstallError { throw uninstallError }
  }
}

/// 桥向外回调的记录。
final class SettingsToolsRecorder {
  var pushes = 0
  var toasts: [(text: String, isError: Bool)] = []
  var launcherOpened = 0
  var revealed: [URL] = []
  var opened: [URL] = []
  var confirmations: [String] = []
  var confirmAnswer = true
  var folderPurposes: [SettingsToolsBridge.FolderPurpose] = []
  var chosenFolder: URL? = URL(fileURLWithPath: "/tmp/picked-plugin")
}

// MARK: - 辅助函数

/// 每个测试用独立的 UserDefaults suite，互不影响。
@MainActor
func isolatedToolsPreferences() -> AppPreferences {
  let suite = "SettingsTools.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return AppPreferences(defaults: defaults)
}

/// 建一个所有原生副作用都被替换掉的桥。
@MainActor
func makeToolsBridge(
  _ tools: FakeToolCenter,
  preferences: AppPreferences? = nil
) -> (SettingsToolsBridge, SettingsToolsRecorder) {
  let recorder = SettingsToolsRecorder()
  let bridge = SettingsToolsBridge(preferences: preferences ?? isolatedToolsPreferences(), tools: tools)
  bridge.pushSnapshot = { recorder.pushes += 1 }
  bridge.toast = { recorder.toasts.append(($0, $1)) }
  bridge.showLauncher = { recorder.launcherOpened += 1 }
  bridge.revealInFinder = { recorder.revealed.append($0) }
  bridge.openFolder = { recorder.opened.append($0) }
  bridge.confirmUninstall = { name, _ in
    recorder.confirmations.append(name)
    return recorder.confirmAnswer
  }
  bridge.chooseFolder = { purpose, _ in
    recorder.folderPurposes.append(purpose)
    return recorder.chosenFolder
  }
  return (bridge, recorder)
}

/// 构造插件一览；未给的字段取常见值。
func toolSummary(
  _ id: String,
  name: String,
  source: ToolPluginSource = .user,
  directory: String = "/tmp/plugins/x",
  status: ToolPluginStatus = .ready,
  permissions: [ToolPermission] = [],
  granted: [ToolPermission] = [],
  domains: [String] = [],
  description: String? = "说明",
  views: [ToolViewSummary] = []
) -> ToolPluginSummary {
  ToolPluginSummary(
    id: id, name: name, version: "1.0.0", description: description, source: source,
    directory: directory, status: status, permissions: permissions, grantedPermissions: granted,
    networkDomains: domains, featureCount: 2, views: views)
}

/// 构造视图一览；未给的字段取常见值（bar、缺省位置 tab.bottom、正在生效）。
func toolViewSummary(
  _ id: String,
  title: String = "Git 分支",
  kind: ToolViewKind = .bar,
  slot: ToolViewSlot = .tabBottom,
  defaultSlot: ToolViewSlot = .tabBottom,
  enabled: Bool = true,
  inactiveReason: ToolViewSummary.InactiveReason? = nil
) -> ToolViewSummary {
  ToolViewSummary(
    id: id, title: title, kind: kind, slot: slot, defaultSlot: defaultSlot, isEnabled: enabled,
    inactiveReason: inactiveReason)
}

/// 发一个动作并等它回执。
@MainActor
func performToolsAction(_ bridge: SettingsToolsBridge, _ action: String, _ payload: [String: Any] = [:]) async -> Bool {
  await withCheckedContinuation { continuation in
    bridge.handle(action: action, payload: payload) { continuation.resume(returning: $0) }
  }
}

/// 让主队列跑完已经排队的任务（合并推送走 DispatchQueue.main.async）。
@MainActor
func drainToolsMainQueue() async {
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }
}
