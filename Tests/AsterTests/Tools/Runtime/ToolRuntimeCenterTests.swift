// 工具中心的扫描、状态持久化与内置条目搜索：有效与无效清单、id 冲突、开发目录、停用与使用记录。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolRuntimeCenterTests {
  @Test func scanFindsBuiltinUserAndDevelopmentPlugins() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try writeToolPlugin(
      at: sandbox.builtinDirectory.appendingPathComponent("aster.sample"), id: "aster.sample", name: "Sample",
      permissions: [], features: [uiFeature()], ui: ["main": "index.html", "height": 300])
    try writeToolPlugin(at: sandbox.pluginsDirectory.appendingPathComponent("echo"), id: "com.example.echo")
    let development = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("dev"), id: "com.example.dev", permissions: ["clipboard.write"],
      features: [uiFeature()], ui: ["main": "index.html"])
    let center = sandbox.makeCenter()
    await center.reloadAndWait()
    #expect(try await center.addDevelopmentFolder(development, window: nil) == "com.example.dev")

    let sources = Dictionary(uniqueKeysWithValues: center.pluginSummaries.map { ($0.id, $0.source) })
    #expect(sources == [
      BuiltinToolCatalog.pluginID: .builtin, "aster.sample": .builtin, "com.example.echo": .user,
      "com.example.dev": .development,
    ])
    #expect(center.pluginStatus(pluginID: "aster.sample") == .ready)
    #expect(center.pluginStatus(pluginID: "com.example.echo") == .needsApproval(.firstRun))
    #expect(center.pluginStatus(pluginID: "com.example.dev") == .ready)
    // 待确认的插件也列进目录：启动器里能看到它，打开时再确认。
    #expect(center.entry(id: "com.example.echo/run") != nil)
    #expect(center.entry(id: "aster.sample/open")?.hasUI == true)
    #expect(center.pluginIssues.isEmpty)
    #expect(center.runtimeInfo(pluginID: "com.example.echo") == nil)
    let info = try #require(center.runtimeInfo(pluginID: "com.example.dev"))
    #expect(info.grantedPermissions == [.clipboardWrite])
    #expect(info.dataDirectory.path == sandbox.appSupport.appendingPathComponent("PluginData/com.example.dev").path)
  }

  @Test func invalidManifestsBecomeIssues() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let broken = sandbox.pluginsDirectory.appendingPathComponent("broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: broken.appendingPathComponent(ToolManifest.fileName))
    let empty = sandbox.pluginsDirectory.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try writeToolPlugin(at: sandbox.pluginsDirectory.appendingPathComponent("good"), id: "com.example.good")
    let center = sandbox.makeCenter()
    await center.reloadAndWait()

    let issuePaths = Set(center.pluginIssues.map(\.path))
    #expect(issuePaths == [broken.path, empty.path])
    #expect(center.pluginSummaries.map(\.id).contains("com.example.good"))
  }

  @Test func duplicateIDKeepsUserPluginAndSkipsDevelopmentFolder() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try writeToolPlugin(at: sandbox.pluginsDirectory.appendingPathComponent("same"), id: "com.example.same", name: "User")
    let development = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("same-dev"), id: "com.example.same", name: "Dev")
    // 直接写状态文件登记开发目录：经 addDevelopmentFolder 会因 id 已存在被拒绝。
    let state = ToolStateFile(developmentFolders: [development.path])
    try FileManager.default.createDirectory(at: sandbox.appSupport, withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: sandbox.stateFile)
    let center = sandbox.makeCenter()
    await center.reloadAndWait()

    #expect(center.pluginSummaries.filter { $0.id == "com.example.same" }.map(\.source) == [.user])
    #expect(center.pluginIssues.map(\.path) == [development.path])
    await #expect(throws: ToolCenterError.alreadyInstalled("com.example.same")) {
      _ = try await center.addDevelopmentFolder(development, window: nil)
    }
  }

  @Test func missingDevelopmentFolderIsReported() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let missing = sandbox.external.appendingPathComponent("gone").path
    try FileManager.default.createDirectory(at: sandbox.appSupport, withIntermediateDirectories: true)
    try JSONEncoder().encode(ToolStateFile(developmentFolders: [missing])).write(to: sandbox.stateFile)
    let center = sandbox.makeCenter()
    await center.reloadAndWait()
    #expect(center.developmentFolders == [missing])
    #expect(center.pluginIssues.map(\.path) == [missing])
  }

  @Test func enabledStateAndUsagePersistAcrossInstances() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try writeToolPlugin(at: sandbox.pluginsDirectory.appendingPathComponent("echo"), id: "com.example.echo")
    let first = sandbox.makeCenter()
    await first.reloadAndWait()
    first.setEnabled(false, pluginID: "com.example.echo")
    #expect(first.pluginStatus(pluginID: "com.example.echo") == .disabled)
    #expect(first.entry(id: "com.example.echo/run") == nil)
    first.recordUse(entryID: "aster.builtin/uuid")
    first.flushState()

    let second = sandbox.makeCenter()
    await second.reloadAndWait()
    #expect(second.pluginStatus(pluginID: "com.example.echo") == .disabled)
    #expect(second.search("", limit: 1).first?.entry.id == "aster.builtin/uuid")
    // 从没授权过的插件重新启用后回到「第一次运行」，而不是「权限变多」。
    second.setEnabled(true, pluginID: "com.example.echo")
    #expect(second.pluginStatus(pluginID: "com.example.echo") == .needsApproval(.firstRun))
  }

  @Test func corruptStateFileIsBackedUpAndReported() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try FileManager.default.createDirectory(at: sandbox.appSupport, withIntermediateDirectories: true)
    try Data("{ broken".utf8).write(to: sandbox.stateFile)
    let center = sandbox.makeCenter()
    center.flushState()
    #expect(center.pluginIssues.map(\.path) == [sandbox.stateFile.path])
    #expect(FileManager.default.fileExists(atPath: sandbox.stateFile.appendingPathExtension("bad").path))
  }

  @Test func builtinEntriesAreSearchableBeforeAnyScan() throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let center = sandbox.makeCenter()
    #expect(center.search("uuid", limit: 5).map(\.entry.id).contains("aster.builtin/uuid"))
    let json = try #require(center.entry(id: "aster.builtin/json"))
    #expect(json.source == .builtin)
    let timestamp = try #require(center.entry(id: "aster.builtin/timestamp"))
    #expect(center.inlineResult(for: timestamp, input: ToolInput(text: "1700000000")) != nil)
    #expect(center.contentMatches(for: ToolInput(text: "1700000000"), limit: 5).map(\.entry.id).contains(timestamp.id))
    #expect(center.inlineResult(for: json, input: ToolInput(text: "{}")) == nil)
  }

  @Test func developmentFolderFingerprintChangesWithNestedFiles() throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let folder = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("dev"), id: "com.example.dev", files: ["web/app.js": "1"])
    let before = ToolPluginScanner.fingerprint(of: folder.path)
    try Data("console.log(2)".utf8).write(to: folder.appendingPathComponent("web/app.js"))
    #expect(before != nil)
    #expect(ToolPluginScanner.fingerprint(of: folder.path) != before)
    #expect(ToolPluginScanner.fingerprint(of: sandbox.external.appendingPathComponent("none").path) != before)
  }
}
