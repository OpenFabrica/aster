// `tool.list` / `tool.run` 控制方法：可运行判定、查询筛选、内置转换与各类拒绝。脚本运行见 ToolControlCommandsScriptTests。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 工具中心替身：固定的功能与状态，不读真实插件目录。
@MainActor
final class FakeToolControlProvider: ToolControlProviding {
  var entries: [ToolControlEntry]
  /// `prepareToRun` 的返回值；缺省按条目里的状态。
  var preparedStatus: [String: ToolPluginStatus] = [:]
  var runtimeInfos: [String: ToolPluginRuntimeInfo] = [:]
  private(set) var preparedPluginIDs: [String] = []

  init(_ entries: [ToolControlEntry]) { self.entries = entries }

  func controlEntries() -> [ToolControlEntry] { entries }

  func prepareToRun(pluginID: String) async -> ToolPluginStatus? {
    preparedPluginIDs.append(pluginID)
    return preparedStatus[pluginID] ?? entries.first { $0.entry.pluginID == pluginID }?.status
  }

  func runtimeInfo(pluginID: String) -> ToolPluginRuntimeInfo? { runtimeInfos[pluginID] }

  func makeContext(workingDirectory: String?, isRemote: Bool) -> ToolContext {
    ToolContext(workingDirectory: workingDirectory, isRemote: isRemote, locale: "en", appearance: "dark")
  }
}

/// 构造一条功能。
func toolControlEntry(
  plugin: String, code: String, title: String, keywords: [String] = [], action: ToolAction,
  source: ToolPluginSource = .user, status: ToolPluginStatus = .ready
) -> ToolControlEntry {
  ToolControlEntry(
    entry: ToolCatalogEntry(
      pluginID: plugin, pluginName: plugin, pluginVersion: "1.0.0", source: source,
      feature: ToolFeature(code: code, title: title, keywords: keywords, action: action)),
    status: status)
}

/// 挂好替身工具中心的 dispatcher；写门禁关着，`tool.*` 不应受它影响。
@MainActor
func toolControlDispatcher(_ provider: FakeToolControlProvider) -> AsterControlDispatcher {
  let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
  let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") {
    AsterControlDispatcher.Policy(allowSendKeys: false, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
  }
  dispatcher.toolControlProvider = provider
  return dispatcher
}

@MainActor
@Suite struct ToolControlCommandsTests {
  /// 覆盖各种动作与状态的一组功能。
  private func sampleProvider() -> FakeToolControlProvider {
    let builtin = BuiltinToolCatalog.pluginID
    return FakeToolControlProvider([
      toolControlEntry(
        plugin: "dev.text", code: "upper", title: "Uppercase", action: .script(ToolScriptAction(command: ["run.sh"]))),
      toolControlEntry(
        plugin: "dev.term", code: "top", title: "Process viewer",
        action: .script(ToolScriptAction(command: ["top"], output: .terminal))),
      toolControlEntry(plugin: "dev.web", code: "board", title: "Board", action: .ui),
      toolControlEntry(
        plugin: builtin, code: "hash", title: "Hash", keywords: ["sha256"],
        action: .builtin(ToolBuiltinAction(handler: .hash)), source: .builtin),
      toolControlEntry(
        plugin: builtin, code: "json", title: "JSON", action: .builtin(ToolBuiltinAction(handler: .json)),
        source: .builtin),
      toolControlEntry(
        plugin: "dev.off", code: "list", title: "Bookmarks",
        action: .script(ToolScriptAction(command: ["run.sh"], output: .list)), status: .disabled),
      toolControlEntry(
        plugin: "dev.new", code: "go", title: "Fresh", action: .script(ToolScriptAction(command: ["run.sh"])),
        status: .needsApproval(.firstRun)),
    ])
  }

  /// 发一个请求并返回响应。
  private func send(_ provider: FakeToolControlProvider, _ method: String, _ params: JSONValue? = nil) async
    -> AsterControlResponse
  {
    await toolControlDispatcher(provider).handle(controlRequest(method, params), client: ControlFakeClient())
  }

  @Test func listMarksOnlyHeadlessReadyCommandsRunnable() async throws {
    let response = await send(sampleProvider(), "tool.list")
    let result = try #require(response.result)
    let tools = try result.decoded(as: ToolListResult.self).tools
    let byID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
    #expect(tools.count == 7)
    #expect(byID["dev.text/upper"]?.runnable == true)
    #expect(byID["dev.text/upper"]?.kind == .script)
    #expect(byID["dev.text/upper"]?.output == "text")
    #expect(byID["dev.text/upper"]?.unavailableReason == nil)
    #expect(byID["dev.term/top"]?.runnable == false)
    #expect(byID["dev.term/top"]?.output == "terminal")
    #expect(byID["dev.web/board"]?.kind == .ui)
    #expect(byID["dev.web/board"]?.runnable == false)
    #expect(byID["aster.builtin/hash"]?.runnable == true)
    #expect(byID["aster.builtin/hash"]?.kind == .builtin)
    #expect(byID["aster.builtin/hash"]?.output == nil)
    #expect(byID["aster.builtin/json"]?.runnable == false)
    #expect(byID["dev.off/list"]?.status == .disabled)
    #expect(byID["dev.off/list"]?.runnable == false)
    #expect(byID["dev.new/go"]?.status == .needsApproval)
    #expect(byID["dev.new/go"]?.unavailableReason?.contains("approval") == true)
    #expect(tools.filter { !$0.runnable }.allSatisfy { $0.unavailableReason?.isEmpty == false })
    // 线上的键是 snake_case，MCP 客户端按这些键读。
    guard case .array(let rows)? = result["tools"], case .object(let row)? = rows.first else {
      Issue.record("tools 不是对象数组")
      return
    }
    #expect(row["plugin_id"] != nil)
    #expect(row["plugin_name"] != nil)
  }

  @Test func listQueryFiltersByKeywordAndKeepsDisabledPlugins() async throws {
    let hash = try #require(await send(sampleProvider(), "tool.list", .object(["query": .string("sha256")])).result)
    #expect(try hash.decoded(as: ToolListResult.self).tools.map(\.id) == ["aster.builtin/hash"])
    let off = try #require(await send(sampleProvider(), "tool.list", .object(["query": .string("bookmarks")])).result)
    #expect(try off.decoded(as: ToolListResult.self).tools.map(\.status) == [.disabled])
  }

  @Test func runBuiltinHashReturnsDigest() async throws {
    let response = await send(
      sampleProvider(), "tool.run", .object(["id": .string("aster.builtin/hash"), "input": .string("abc")]))
    let result = try #require(response.result).decoded(as: ToolRunResult.self)
    #expect(result.output == "text")
    #expect(result.text == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(result.truncated == false)
  }

  @Test func runBuiltinRejectsInputItCannotProcess() async {
    let response = await send(sampleProvider(), "tool.run", .object(["id": .string("aster.builtin/hash")]))
    #expect(response.error?.code == .invalidParams)
  }

  @Test func runUnknownIDIsNotFound() async {
    let response = await send(sampleProvider(), "tool.run", .object(["id": .string("dev.none/x")]))
    #expect(response.error?.code == .notFound)
  }

  @Test func runRejectsInterfaceOnlyCommands() async {
    for id in ["dev.web/board", "dev.term/top", "aster.builtin/json"] {
      let response = await send(sampleProvider(), "tool.run", .object(["id": .string(id)]))
      #expect(response.error?.code == .invalidParams, "\(id)")
      #expect(response.error?.message.contains("headlessly") == true, "\(id)")
    }
  }

  @Test func runRejectsPluginsThatNeedApprovalOrAreDisabledWithoutPreparing() async {
    let provider = sampleProvider()
    let approval = await send(provider, "tool.run", .object(["id": .string("dev.new/go")]))
    #expect(approval.error?.code == .invalidParams)
    #expect(approval.error?.message.contains("open this tool once in Aster") == true)
    let disabled = await send(provider, "tool.run", .object(["id": .string("dev.off/list")]))
    #expect(disabled.error?.code == .invalidParams)
    #expect(disabled.error?.message.contains("disabled") == true)
    #expect(provider.preparedPluginIDs.isEmpty)
  }

  @Test func runValidatesID() async {
    let response = await send(sampleProvider(), "tool.run", .object(["id": .string("no-slash")]))
    #expect(response.error?.code == .invalidParams)
  }

  @Test func toolCenterControlEntriesIncludeDisabledPlugins() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try writeToolPlugin(at: sandbox.pluginsDirectory.appendingPathComponent("echo"), id: "com.example.echo")
    let center = sandbox.makeCenter()
    await center.reloadAndWait()
    center.setEnabled(false, pluginID: "com.example.echo")
    #expect(center.entry(id: "com.example.echo/run") == nil)
    let entries = center.controlEntries()
    #expect(entries.first { $0.entry.id == "com.example.echo/run" }?.status == .disabled)
    #expect(entries.contains { $0.entry.id == "\(BuiltinToolCatalog.pluginID)/hash" && $0.status == .ready })
  }

  @Test func truncationStopsOnCharacterBoundary() {
    let (text, truncated) = AsterControlDispatcher.truncatedToolText("aéé", maximumUTF8Bytes: 4)
    #expect(text == "aé")
    #expect(truncated)
    let short = AsterControlDispatcher.truncatedToolText("abc", maximumUTF8Bytes: 3)
    #expect(short.text == "abc")
    #expect(!short.truncated)
  }
}
