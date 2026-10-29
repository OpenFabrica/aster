// `tool.run` 跑真实脚本：临时目录里造 `#!/bin/sh` 插件，经替身工具中心提供运行信息。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolControlCommandsScriptTests {
  /// 临时插件：`bin/run.sh` 写入给定脚本体，按输出方式登记成一个功能。
  private struct ScriptPlugin {
    let root: URL
    let provider: FakeToolControlProvider
    let id: String
  }

  /// 造插件目录与替身；调用方负责删除 `root`。
  private func makePlugin(_ body: String, output: ToolScriptOutput = .text) throws -> ScriptPlugin {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-tool-control-\(UUID().uuidString)", isDirectory: true)
    let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
    let script = pluginDirectory.appendingPathComponent("bin/run.sh")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let action = ToolScriptAction(command: ["bin/run.sh"], output: output)
    let pluginID = "com.example.ctl"
    let entry = toolControlEntry(plugin: pluginID, code: "run", title: "Run", action: .script(action))
    let provider = FakeToolControlProvider([entry])
    provider.runtimeInfos[pluginID] = ToolPluginRuntimeInfo(
      manifest: ToolManifest(
        id: pluginID, name: "Ctl", version: "1.0.0", permissions: [.exec], features: [entry.entry.feature]),
      source: .user, directory: pluginDirectory, dataDirectory: root.appendingPathComponent("data", isDirectory: true),
      grantedPermissions: [.exec], grantedNetworkDomains: [])
    return ScriptPlugin(root: root, provider: provider, id: entry.entry.id)
  }

  /// 运行插件并返回响应。
  private func run(_ plugin: ScriptPlugin, input: String? = nil, cwd: String? = nil) async -> AsterControlResponse {
    var params: [String: JSONValue] = ["id": .string(plugin.id)]
    if let input { params["input"] = .string(input) }
    if let cwd { params["cwd"] = .string(cwd) }
    return await toolControlDispatcher(plugin.provider).handle(
      controlRequest("tool.run", .object(params)), client: ControlFakeClient())
  }

  @Test func textScriptReadsStdinAndReceivesGivenDirectory() async throws {
    let plugin = try makePlugin(#"printf 'got:%s:' "$ASTER_CWD"; cat"#)
    defer { try? FileManager.default.removeItem(at: plugin.root) }
    let response = await run(plugin, input: "hello", cwd: plugin.root.path)
    let result = try #require(response.result).decoded(as: ToolRunResult.self)
    #expect(result.output == "text")
    #expect(result.text == "got:\(plugin.root.path):hello")
    #expect(result.truncated == false)
    #expect(result.durationMs >= 0)
    #expect(plugin.provider.preparedPluginIDs == ["com.example.ctl"])
  }

  @Test func listScriptReturnsItems() async throws {
    let plugin = try makePlugin(#"printf '{"items":[{"title":"one","value":"1"},{"title":"two"}]}'"#, output: .list)
    defer { try? FileManager.default.removeItem(at: plugin.root) }
    let result = try #require(await run(plugin).result).decoded(as: ToolRunResult.self)
    #expect(result.output == "list")
    #expect(result.items?.map(\.title) == ["one", "two"])
    #expect(result.items?.first?.value == "1")
    #expect(result.text == nil)
  }

  @Test func noneScriptOnlyReportsCompletion() async throws {
    let plugin = try makePlugin("cat >/dev/null", output: .none)
    defer { try? FileManager.default.removeItem(at: plugin.root) }
    let result = try #require(await run(plugin, input: "x").result).decoded(as: ToolRunResult.self)
    #expect(result.output == "none")
    #expect(result.text == nil)
    #expect(result.items == nil)
  }

  @Test func longTextOutputIsTruncated() async throws {
    let plugin = try makePlugin("head -c 600000 /dev/zero | tr '\\000' a")
    defer { try? FileManager.default.removeItem(at: plugin.root) }
    let result = try #require(await run(plugin).result).decoded(as: ToolRunResult.self)
    #expect(result.truncated)
    #expect(result.text?.utf8.count == ToolControlLimits.maximumOutputBytes)
  }

  @Test func failingScriptReportsStderr() async throws {
    let plugin = try makePlugin("echo broken >&2; exit 3")
    defer { try? FileManager.default.removeItem(at: plugin.root) }
    let response = await run(plugin)
    #expect(response.error?.code == .internalError)
    #expect(response.error?.message.contains("broken") == true)
  }

  @Test func filesChangedSinceApprovalAreRejectedBeforeRunning() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("aster-ctl-\(UUID().uuidString)")
    let plugin = try makePlugin("touch '\(marker.path)'")
    defer { try? FileManager.default.removeItem(at: plugin.root) }
    plugin.provider.preparedStatus["com.example.ctl"] = .needsApproval(.filesChanged)
    let response = await run(plugin)
    #expect(response.error?.code == .invalidParams)
    #expect(response.error?.message.contains("approval") == true)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}
