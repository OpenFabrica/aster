// 卸载与开发目录：按「撤下会话 → WebKit 存储 → 插件数据 → 插件目录」的顺序删除，WebKit 存储仍在使用时重试，
// 一直删不掉就停下且不动任何文件；开发插件只取消登记；设置页拿到的开发目录与登记字符串逐字一致。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolRuntimeUninstallTests {
  @Test func uninstallTrashesPluginAndDeletesData() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let source = try writeToolPlugin(at: sandbox.external.appendingPathComponent("echo"), id: "com.example.echo")
    let center = sandbox.makeCenter()
    _ = try await center.installPlugin(from: source, window: nil)
    let data = center.dataDirectory(for: "com.example.echo")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: data.appendingPathComponent("storage.json"))
    center.recordUse(entryID: "com.example.echo/run")

    try await center.uninstall(pluginID: "com.example.echo")
    let installed = sandbox.pluginsDirectory.appendingPathComponent("com.example.echo")
    #expect(sandbox.trash.removed.map(\.path) == [installed.path])
    #expect(!FileManager.default.fileExists(atPath: data.path))
    #expect(sandbox.websiteData.removed == [ToolPluginIdentity.dataStoreIdentifier(pluginID: "com.example.echo")])
    #expect(center.pluginStatus(pluginID: "com.example.echo") == nil)
    center.flushState()
    let state = try JSONDecoder().decode(ToolStateFile.self, from: Data(contentsOf: sandbox.stateFile))
    #expect(state.plugins["com.example.echo"] == nil)
    #expect(state.usage.records["com.example.echo/run"] == nil)

    await #expect(throws: ToolCenterError.notRemovable(BuiltinToolCatalog.pluginID)) {
      try await center.uninstall(pluginID: BuiltinToolCatalog.pluginID)
    }
    await #expect(throws: ToolCenterError.pluginNotFound("com.example.none")) {
      try await center.uninstall(pluginID: "com.example.none")
    }
  }

  @Test func uninstallRetriesWhileWebsiteDataIsInUse() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let source = try writeToolPlugin(at: sandbox.external.appendingPathComponent("echo"), id: "com.example.echo")
    let center = sandbox.makeCenter()
    _ = try await center.installPlugin(from: source, window: nil)
    sandbox.websiteData.failuresRemaining = 2

    try await center.uninstall(pluginID: "com.example.echo")
    #expect(sandbox.websiteData.attempts == 3)
    #expect(center.pluginStatus(pluginID: "com.example.echo") == nil)
  }

  @Test func uninstallStopsBeforeDeletingFilesWhenWebsiteDataStaysInUse() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let source = try writeToolPlugin(at: sandbox.external.appendingPathComponent("echo"), id: "com.example.echo")
    let center = sandbox.makeCenter()
    _ = try await center.installPlugin(from: source, window: nil)
    let data = center.dataDirectory(for: "com.example.echo")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    sandbox.websiteData.failuresRemaining = Int.max

    let error = await #expect(throws: ToolCenterError.self) { try await center.uninstall(pluginID: "com.example.echo") }
    if case .fileOperationFailed? = error {} else { Issue.record("期望 fileOperationFailed，实际 \(String(describing: error))") }
    #expect(sandbox.websiteData.attempts == ToolCenter.websiteDataRemovalAttempts)
    #expect(sandbox.trash.removed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: data.path))
    #expect(center.pluginStatus(pluginID: "com.example.echo") == .ready)
  }

  @Test func uninstallingDevelopmentPluginOnlyUnregistersFolder() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let folder = try writeToolPlugin(at: sandbox.external.appendingPathComponent("dev"), id: "com.example.dev")
    let center = sandbox.makeCenter()
    _ = try await center.addDevelopmentFolder(folder, window: nil)

    try await center.uninstall(pluginID: "com.example.dev")
    #expect(center.developmentFolders.isEmpty)
    #expect(sandbox.trash.removed.isEmpty)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ToolManifest.fileName).path))
    #expect(center.pluginStatus(pluginID: "com.example.dev") == nil)
  }

  @Test func developmentSummaryDirectoryIsTheRegisteredString() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let folder = try writeToolPlugin(at: sandbox.external.appendingPathComponent("dev"), id: "com.example.dev")
    // 经符号链接登记：扫描会解析成真实目录，但设置页拿到的仍是登记时的原字符串。
    let link = sandbox.external.appendingPathComponent("dev-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    try FileManager.default.createDirectory(at: sandbox.appSupport, withIntermediateDirectories: true)
    try JSONEncoder().encode(ToolStateFile(developmentFolders: [link.path])).write(to: sandbox.stateFile)
    let center = sandbox.makeCenter()
    await center.reloadAndWait()

    let summary = try #require(center.pluginSummaries.first { $0.id == "com.example.dev" })
    #expect(summary.directory == link.path)
    #expect(center.developmentFolders == [link.path])
    center.removeDevelopmentFolder(summary.directory)
    #expect(await waitForToolCondition { center.pluginStatus(pluginID: "com.example.dev") == nil })
    #expect(center.developmentFolders.isEmpty)
  }
}
