// 设置页「工具」协作者：快照形状与排序、动作校验与调用、合并推送、确认框与窗口关闭后不回调。
import AppKit
import Combine
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// MARK: - 快照

@Test("工具快照：形状与文档一致，插件按来源与名称排序，权限按风险从高到低")
@MainActor
func settingsToolsSnapshotShapeAndOrder() throws {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [
    toolSummary("aster.builtin", name: "Aster 内置工具", source: .builtin, directory: ""),
    toolSummary("com.example.dev", name: "开发插件", source: .development, directory: "/src/dev"),
    toolSummary(
      "com.example.zeta", name: "Zeta", permissions: [.notify, .exec, .clipboardRead, .clipboardWrite],
      granted: [.notify, .exec], domains: [], description: nil),
    toolSummary("com.example.alpha", name: "Alpha", status: .disabled),
  ]
  tools.pluginIssues = [ToolPluginIssue(path: "/p/broken", message: "清单无效")]
  tools.developmentFolders = ["/src/dev"]
  let preferences = isolatedToolsPreferences()
  preferences.setCompatibilityValue(.string("controlGrave"), forKey: "quickTerminal.shortcut")
  let (bridge, _) = makeToolsBridge(tools, preferences: preferences)

  let snapshot = bridge.snapshot()
  #expect(Set(snapshot.keys) == [
    "launcherShortcut", "quickTerminalShortcut", "pluginsDirectory", "plugins", "viewSlots", "issues",
    "developmentFolders",
  ])
  #expect(snapshot["launcherShortcut"] as? String == "none")
  #expect(snapshot["quickTerminalShortcut"] as? String == "controlGrave")
  #expect(snapshot["pluginsDirectory"] as? String == tools.pluginsDirectory.path)
  #expect(snapshot["developmentFolders"] as? [String] == ["/src/dev"])
  let issues = try #require(snapshot["issues"] as? [[String: String]])
  #expect(issues == [["path": "/p/broken", "message": "清单无效"]])

  let plugins = try #require(snapshot["plugins"] as? [[String: Any]])
  #expect(plugins.compactMap { $0["id"] as? String }
    == ["com.example.alpha", "com.example.zeta", "com.example.dev", "aster.builtin"])
  let zeta = plugins[1]
  #expect(Set(zeta.keys) == [
    "id", "name", "version", "description", "source", "directory", "status", "statusReason", "enabled",
    "permissions", "networkDomains", "featureCount", "removable", "views",
  ])
  #expect(zeta["description"] is NSNull)
  #expect(zeta["statusReason"] is NSNull)
  #expect(zeta["status"] as? String == "ready")
  #expect(zeta["source"] as? String == "user")
  #expect(zeta["featureCount"] as? Int == 2)
  #expect(zeta["removable"] as? Bool == true)
  let permissions = try #require(zeta["permissions"] as? [[String: Any]])
  // 同为低风险的 notify 与 clipboard.write 保持清单里的先后。
  #expect(permissions.compactMap { $0["id"] as? String } == ["exec", "clipboard.read", "notify", "clipboard.write"])
  #expect(permissions.compactMap { $0["risk"] as? String } == ["high", "medium", "low", "low"])
  #expect(permissions.compactMap { $0["granted"] as? Bool } == [true, false, true, false])
  #expect(permissions.first?["title"] as? String == ToolPermission.exec.localizedTitle)

  let alpha = plugins[0]
  #expect(alpha["status"] as? String == "disabled")
  #expect(alpha["enabled"] as? Bool == false)
  let builtin = plugins[3]
  #expect(builtin["removable"] as? Bool == false)
  #expect(builtin["directory"] as? String == "")
  #expect(JSONSerialization.isValidJSONObject(snapshot))
}

@Test("工具快照：需要确认的原因映射成 statusReason 标识")
@MainActor
func settingsToolsSnapshotMapsApprovalReasons() {
  let reasons: [(ToolApprovalReason, String)] = [
    (.firstRun, "firstRun"), (.filesChanged, "filesChanged"),
    (.permissionsAdded([.exec]), "permissionsAdded"), (.networkDomainsAdded(["api.example.com"]), "networkDomainsAdded"),
  ]
  for (reason, identifier) in reasons {
    let row = SettingsToolsBridge.pluginRow(toolSummary("com.example.a", name: "A", status: .needsApproval(reason)))
    #expect(row["status"] as? String == "needsApproval")
    #expect(row["statusReason"] as? String == identifier)
    #expect(row["enabled"] as? Bool == true)
  }
}

// MARK: - 同步动作

@Test("工具动作：setEnabled 只认存在的 id 与 JSON 布尔值，调用后推一次快照")
@MainActor
func settingsToolsSetEnabledValidatesPayload() async {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [toolSummary("com.example.a", name: "A")]
  let (bridge, recorder) = makeToolsBridge(tools)
  bridge.start()

  #expect(await performToolsAction(bridge, "tools.setEnabled", ["id": "com.example.a", "enabled": false]))
  #expect(tools.enabledCalls.map(\.id) == ["com.example.a"] && tools.enabledCalls.map(\.enabled) == [false])
  // 工具中心同步发出的 changes 不应再触发第二次推送。
  await drainToolsMainQueue()
  #expect(recorder.pushes == 1)

  #expect(await performToolsAction(bridge, "tools.setEnabled", ["id": "com.example.a", "enabled": 1]) == false)
  #expect(await performToolsAction(bridge, "tools.setEnabled", ["enabled": true]) == false)
  #expect(await performToolsAction(bridge, "tools.setEnabled", ["id": "com.example.missing", "enabled": true]) == false)
  #expect(tools.enabledCalls.count == 1)
  #expect(recorder.toasts.map(\.text) == [
    L("参数无效"), L("参数无效"), ToolCenterError.pluginNotFound("com.example.missing").localizedDescription,
  ])
  #expect(recorder.toasts.allSatisfy { $0.isError })
}

@Test("工具动作：未知动作与未知插件一律拒绝，不调用工具中心")
@MainActor
func settingsToolsRejectUnknownActionsAndPlugins() async {
  let tools = FakeToolCenter()
  let (bridge, recorder) = makeToolsBridge(tools)
  #expect(await performToolsAction(bridge, "tools.bogus") == false)
  for action in ["tools.approve", "tools.uninstall", "tools.reveal"] {
    #expect(await performToolsAction(bridge, action, ["id": "com.example.none"]) == false)
  }
  #expect(tools.approveCalls.isEmpty && tools.uninstalled.isEmpty && recorder.revealed.isEmpty)
  #expect(recorder.confirmations.isEmpty)
  #expect(recorder.toasts.count == 4 && recorder.toasts.allSatisfy { $0.isError })
}

@Test("工具动作：removeDevelopmentFolder 只认已登记的路径")
@MainActor
func settingsToolsRemoveDevelopmentFolderRequiresRegisteredPath() async {
  let tools = FakeToolCenter()
  tools.developmentFolders = ["/src/dev"]
  let (bridge, recorder) = makeToolsBridge(tools)
  #expect(await performToolsAction(bridge, "tools.removeDevelopmentFolder", ["path": "/etc"]) == false)
  #expect(await performToolsAction(bridge, "tools.removeDevelopmentFolder", ["path": 42]) == false)
  #expect(tools.removedFolders.isEmpty)
  #expect(await performToolsAction(bridge, "tools.removeDevelopmentFolder", ["path": "/src/dev"]))
  #expect(tools.removedFolders == ["/src/dev"])
  #expect(recorder.pushes == 1)
}

@Test("工具动作：openLauncher 发出 asterShowToolLauncher 通知，reload 交给工具中心")
@MainActor
func settingsToolsOpenLauncherAndReload() async {
  let tools = FakeToolCenter()
  // 用默认的 showLauncher，确认真的发了通知。
  let bridge = SettingsToolsBridge(preferences: isolatedToolsPreferences(), tools: tools)
  var objects: [Any?] = []
  let observation = NotificationCenter.default.publisher(for: .asterShowToolLauncher)
    .sink { objects.append($0.object) }
  defer { observation.cancel() }
  #expect(await performToolsAction(bridge, "tools.openLauncher"))
  #expect(objects.count == 1)
  #expect(objects.first.flatMap { $0 } == nil)

  #expect(await performToolsAction(bridge, "tools.reload"))
  #expect(tools.reloadCount == 1)
}

@Test("工具动作：在 Finder 中显示与打开插件目录")
@MainActor
func settingsToolsRevealAndOpenPluginsFolder() async throws {
  let tools = FakeToolCenter()
  let existing = FileManager.default.temporaryDirectory
    .appendingPathComponent("AsterToolsReveal-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
  defer {
    try? FileManager.default.removeItem(at: existing)
    try? FileManager.default.removeItem(at: tools.pluginsDirectory.deletingLastPathComponent())
  }
  tools.pluginSummaries = [
    toolSummary("aster.builtin", name: "内置", source: .builtin, directory: ""),
    toolSummary("com.example.gone", name: "Gone", directory: "/nonexistent/aster-plugin"),
    toolSummary("com.example.here", name: "Here", directory: existing.path),
  ]
  let (bridge, recorder) = makeToolsBridge(tools)
  #expect(await performToolsAction(bridge, "tools.reveal", ["id": "aster.builtin"]) == false)
  #expect(await performToolsAction(bridge, "tools.reveal", ["id": "com.example.gone"]) == false)
  #expect(await performToolsAction(bridge, "tools.reveal", ["id": "com.example.here"]))
  #expect(recorder.revealed.map(\.path) == [existing.path])
  #expect(recorder.toasts.map(\.text) == [L("内置原生工具没有插件目录"), L("插件目录不存在：\("/nonexistent/aster-plugin")")])

  // 插件目录还不存在：先创建再打开。
  #expect(!FileManager.default.fileExists(atPath: tools.pluginsDirectory.path))
  #expect(await performToolsAction(bridge, "tools.openPluginsFolder"))
  #expect(FileManager.default.fileExists(atPath: tools.pluginsDirectory.path))
  #expect(recorder.opened == [tools.pluginsDirectory])
}

// MARK: - 异步动作

@Test("工具动作：approve 把设置窗口交给工具中心；用户拒绝时静默")
@MainActor
func settingsToolsApprovePassesWindow() async {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [toolSummary("com.example.a", name: "A", status: .needsApproval(.firstRun))]
  let (bridge, recorder) = makeToolsBridge(tools)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
  bridge.window = { window }

  #expect(await performToolsAction(bridge, "tools.approve", ["id": "com.example.a"]))
  #expect(tools.approveCalls.map(\.id) == ["com.example.a"])
  #expect(tools.approveCalls.first?.window === window)
  #expect(recorder.pushes == 1)

  tools.approveResult = false
  #expect(await performToolsAction(bridge, "tools.approve", ["id": "com.example.a"]) == false)
  #expect(recorder.toasts.isEmpty)
  #expect(recorder.pushes == 2)
}

@Test("工具动作：卸载先原生确认；内置与开发中的插件不能卸载")
@MainActor
func settingsToolsUninstallConfirmsFirst() async {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [
    toolSummary("com.example.user", name: "用户插件"),
    toolSummary("aster.builtin", name: "内置", source: .builtin, directory: ""),
    toolSummary("com.example.dev", name: "开发插件", source: .development, directory: "/src/dev"),
  ]
  let (bridge, recorder) = makeToolsBridge(tools)

  recorder.confirmAnswer = false
  #expect(await performToolsAction(bridge, "tools.uninstall", ["id": "com.example.user"]) == false)
  #expect(recorder.confirmations == ["用户插件"])
  #expect(tools.uninstalled.isEmpty && recorder.toasts.isEmpty)

  recorder.confirmAnswer = true
  #expect(await performToolsAction(bridge, "tools.uninstall", ["id": "com.example.user"]))
  #expect(tools.uninstalled == ["com.example.user"])
  #expect(recorder.toasts.last?.text == L("已卸载插件「\("用户插件")」"))
  #expect(recorder.toasts.last?.isError == false)

  for id in ["aster.builtin", "com.example.dev"] {
    #expect(await performToolsAction(bridge, "tools.uninstall", ["id": id]) == false)
  }
  #expect(recorder.confirmations.count == 2)
  #expect(tools.uninstalled == ["com.example.user"])
  #expect(recorder.toasts.suffix(2).map(\.text) == [
    ToolCenterError.notRemovable("aster.builtin").localizedDescription,
    L("开发中的插件不会被卸载，请在「开发」里移除它的目录"),
  ])

  tools.uninstallError = .fileOperationFailed("磁盘只读")
  #expect(await performToolsAction(bridge, "tools.uninstall", ["id": "com.example.user"]) == false)
  #expect(recorder.toasts.last?.text == ToolCenterError.fileOperationFailed("磁盘只读").localizedDescription)
  #expect(recorder.toasts.last?.isError == true)
}

@Test("工具动作：从文件夹安装与添加开发目录走原生选择框；取消与 declined 都静默")
@MainActor
func settingsToolsInstallAndAddDevelopmentFolder() async {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [toolSummary("com.example.new", name: "新插件")]
  let (bridge, recorder) = makeToolsBridge(tools)
  let picked = URL(fileURLWithPath: "/tmp/picked-plugin")

  #expect(await performToolsAction(bridge, "tools.installFromFolder"))
  #expect(tools.installedFolders == [picked])
  #expect(recorder.toasts.last?.text == L("已安装插件「\("新插件")」"))
  #expect(await performToolsAction(bridge, "tools.addDevelopmentFolder"))
  #expect(tools.developmentAdded == [picked])
  #expect(recorder.folderPurposes == [.install, .development])

  recorder.chosenFolder = nil
  #expect(await performToolsAction(bridge, "tools.installFromFolder") == false)
  #expect(tools.installedFolders.count == 1)

  recorder.chosenFolder = picked
  let toastCount = recorder.toasts.count
  tools.addResult = .failure(.declined)
  #expect(await performToolsAction(bridge, "tools.installFromFolder") == false)
  #expect(recorder.toasts.count == toastCount)

  tools.addResult = .failure(.invalidManifest("缺少 id"))
  #expect(await performToolsAction(bridge, "tools.addDevelopmentFolder") == false)
  #expect(recorder.toasts.last?.text == ToolCenterError.invalidManifest("缺少 id").localizedDescription)
  #expect(recorder.toasts.last?.isError == true)
}

@Test("工具动作：确认框未关时不再弹第二个；设置窗口关闭后完成的动作不再回调")
@MainActor
func settingsToolsModalActionsDoNotStackOrOutliveWindow() async {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [toolSummary("com.example.user", name: "用户插件")]
  let (bridge, recorder) = makeToolsBridge(tools)
  var pending: CheckedContinuation<Bool, Never>?
  bridge.confirmUninstall = { _, _ in await withCheckedContinuation { pending = $0 } }

  var first: Bool?
  bridge.handle(action: "tools.uninstall", payload: ["id": "com.example.user"]) { first = $0 }
  for _ in 0..<50 where pending == nil { await Task.yield() }
  #expect(pending != nil)
  // 第一个确认框还开着：第二次点击直接以失败结束，不再弹框。
  #expect(await performToolsAction(bridge, "tools.installFromFolder") == false)
  #expect(recorder.folderPurposes.isEmpty)

  // 用户确认时设置窗口已经关了：卸载照常执行，但不再推快照、提示或回执。
  bridge.isPresented = { false }
  pending?.resume(returning: true)
  for _ in 0..<50 where tools.uninstalled.isEmpty { await Task.yield() }
  await drainToolsMainQueue()
  #expect(tools.uninstalled == ["com.example.user"])
  #expect(first == nil)
  #expect(recorder.pushes == 0 && recorder.toasts.isEmpty)

  // 动作结束后锁已释放。
  bridge.isPresented = { true }
  #expect(await performToolsAction(bridge, "tools.installFromFolder"))
}

// MARK: - 合并推送

@Test("工具中心连发 changes：合并成下一轮主队列的一次推送")
@MainActor
func settingsToolsCoalescesChangeBursts() async {
  let tools = FakeToolCenter()
  let (bridge, recorder) = makeToolsBridge(tools)
  bridge.start()
  bridge.start()
  tools.subject.send()
  tools.subject.send()
  tools.subject.send()
  #expect(recorder.pushes == 0)
  await drainToolsMainQueue()
  #expect(recorder.pushes == 1)
  tools.subject.send()
  await drainToolsMainQueue()
  #expect(recorder.pushes == 2)
}
