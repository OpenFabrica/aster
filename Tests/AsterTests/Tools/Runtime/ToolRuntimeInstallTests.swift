// 工具中心的管理流程：从文件夹安装、授权（注入确认器）、文件改动后重新确认、开发目录登记与取消。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolRuntimeInstallTests {
  @Test func installCopiesPluginAndRecordsApproval() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let source = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("echo"), id: "com.example.echo", files: ["bin/tool.sh": "x"])
    let center = sandbox.makeCenter()
    await center.reloadAndWait()

    #expect(try await center.installPlugin(from: source, window: nil) == "com.example.echo")
    let installed = sandbox.pluginsDirectory.appendingPathComponent("com.example.echo")
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("bin/tool.sh").path))
    #expect(center.pluginStatus(pluginID: "com.example.echo") == .ready)
    #expect(sandbox.approver.prompts.map(\.kind) == [.install])
    #expect(sandbox.approver.prompts.first?.directory == source.path)
    // 安装用的临时目录不能留下。
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.pluginsDirectory.path)
    #expect(leftovers == ["com.example.echo"])
    await #expect(throws: ToolCenterError.alreadyInstalled("com.example.echo")) {
      _ = try await center.installPlugin(from: source, window: nil)
    }

    center.flushState()
    let reloaded = sandbox.makeCenter()
    await reloaded.reloadAndWait()
    #expect(reloaded.pluginStatus(pluginID: "com.example.echo") == .ready)
  }

  @Test func declinedOrInvalidInstallLeavesNothingBehind() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let source = try writeToolPlugin(at: sandbox.external.appendingPathComponent("echo"), id: "com.example.echo")
    let invalid = sandbox.external.appendingPathComponent("invalid")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: invalid.appendingPathComponent(ToolManifest.fileName))
    let center = sandbox.makeCenter()
    sandbox.approver.answer = false

    await #expect(throws: ToolCenterError.declined) { _ = try await center.installPlugin(from: source, window: nil) }
    let error = await #expect(throws: ToolCenterError.self) {
      _ = try await center.installPlugin(from: invalid, window: nil)
    }
    if case .invalidManifest? = error {} else { Issue.record("期望 invalidManifest，实际 \(String(describing: error))") }
    #expect(!FileManager.default.fileExists(atPath: sandbox.pluginsDirectory.appendingPathComponent("com.example.echo").path))
    let staging = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.pluginsDirectory.path)) ?? []
    #expect(staging.isEmpty)
    #expect(center.pluginStatus(pluginID: "com.example.echo") == nil)
  }

  @Test func approvalGrantsPermissionsAndFileChangesAskAgain() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let plugin = try writeToolPlugin(
      at: sandbox.pluginsDirectory.appendingPathComponent("echo"), id: "com.example.echo", files: ["a.txt": "1"])
    let center = sandbox.makeCenter()
    await center.reloadAndWait()

    sandbox.approver.answer = false
    #expect(await center.approve(pluginID: "com.example.echo", window: nil) == false)
    #expect(center.pluginStatus(pluginID: "com.example.echo") == .needsApproval(.firstRun))
    #expect(sandbox.approver.prompts.last?.kind == .approval(.firstRun))

    sandbox.approver.answer = true
    #expect(await center.approve(pluginID: "com.example.echo", window: nil))
    #expect(center.pluginStatus(pluginID: "com.example.echo") == .ready)
    #expect(center.runtimeInfo(pluginID: "com.example.echo")?.grantedPermissions == [.exec])
    // 已可运行时再请求不再弹确认。
    let promptCount = sandbox.approver.prompts.count
    #expect(await center.approve(pluginID: "com.example.echo", window: nil))
    #expect(sandbox.approver.prompts.count == promptCount)

    // 原地改文件（监听收不到）：运行前的摘要核对要拦住。
    try Data("2".utf8).write(to: plugin.appendingPathComponent("a.txt"))
    #expect(await center.prepareToRun(pluginID: "com.example.echo") == .needsApproval(.filesChanged))
    #expect(center.entry(id: "com.example.echo/run") != nil)
  }

  @Test func addedPermissionsNeedApprovalAgain() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let folder = try writeToolPlugin(at: sandbox.external.appendingPathComponent("dev"), id: "com.example.dev")
    let center = sandbox.makeCenter()
    _ = try await center.addDevelopmentFolder(folder, window: nil)
    #expect(sandbox.approver.prompts.map(\.kind) == [.developmentFolder])
    #expect(center.pluginStatus(pluginID: "com.example.dev") == .ready)

    // 开发来源不比对摘要；但多要权限仍要重新确认。
    try writeToolPlugin(at: folder, id: "com.example.dev", permissions: ["exec", "notify"])
    await center.reloadAndWait()
    #expect(center.pluginStatus(pluginID: "com.example.dev") == .needsApproval(.permissionsAdded([.notify])))

    center.removeDevelopmentFolder(folder.path)
    #expect(await waitForToolCondition { center.pluginStatus(pluginID: "com.example.dev") == nil })
    #expect(center.developmentFolders.isEmpty)
    // 文件夹本身不动。
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ToolManifest.fileName).path))
  }

  @Test func disabledPluginIsReenabledByApproveWithoutPrompt() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try writeToolPlugin(
      at: sandbox.builtinDirectory.appendingPathComponent("aster.sample"), id: "aster.sample", permissions: [],
      features: [uiFeature()], ui: ["main": "index.html"])
    let center = sandbox.makeCenter()
    await center.reloadAndWait()
    center.setEnabled(false, pluginID: "aster.sample")
    #expect(center.entry(id: "aster.sample/open") == nil)
    #expect(await center.approve(pluginID: "aster.sample", window: nil))
    #expect(sandbox.approver.prompts.isEmpty)
    #expect(center.pluginStatus(pluginID: "aster.sample") == .ready)
    #expect(center.entry(id: "aster.sample/open") != nil)
  }
}
