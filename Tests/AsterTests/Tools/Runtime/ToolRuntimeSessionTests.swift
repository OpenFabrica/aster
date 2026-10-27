// 工具会话的分派：内置原生工具、先授权再运行的脚本、list 去抖重跑、none 完成后关闭、terminal 交给容器。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolRuntimeSessionTests {
  /// 打开一个功能并加载视图（触发首次判断与运行）。
  private func open(
    _ entryID: String, in center: ToolCenter, host: FakeToolSessionHost, text: String? = nil
  ) throws -> ToolSessionViewController {
    let entry = try #require(center.entry(id: entryID))
    let request = ToolLaunchRequest(entry: entry, input: ToolInput(text: text, source: .typed), origin: nil)
    let session = center.makeSession(for: request, host: host)
    _ = session.view
    return session
  }

  @Test func builtinToolShowsNativeContent() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let center = sandbox.makeCenter()
    let host = FakeToolSessionHost()
    let session = try open("aster.builtin/uuid", in: center, host: host)
    defer { session.teardown() }
    #expect(session.primaryResultText?.count == 36)
    #expect(!host.heights.isEmpty)
    #expect(session.preferredHeight > 0)
  }

  @Test func scriptAsksForApprovalThenRunsAndShowsText() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    try writeToolPlugin(at: sandbox.pluginsDirectory.appendingPathComponent("echo"), id: "com.example.echo")
    let center = sandbox.makeCenter()
    await center.reloadAndWait()
    let host = FakeToolSessionHost()
    let session = try open("com.example.echo/run", in: center, host: host)
    defer { session.teardown() }
    #expect(session.primaryResultText == nil)
    #expect(sandbox.approver.prompts.isEmpty, "打开工具时只显示提示，点按钮才弹确认")

    #expect(await center.approve(pluginID: "com.example.echo", window: nil))
    #expect(await waitForToolCondition { session.primaryResultText == "hi" })
  }

  @Test func listScriptRerunsWhenQueryChanges() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let script = "printf '{\"items\":[{\"title\":\"%s\",\"value\":\"v-%s\"}]}' \"$ASTER_QUERY\" \"$ASTER_QUERY\""
    let feature: [String: Any] = [
      "code": "find", "title": "Find", "keywords": ["find"],
      "action": ["type": "script", "command": ["/bin/sh", "-c", script], "output": "list"],
    ]
    let folder = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("list"), id: "com.example.list", features: [feature])
    let center = sandbox.makeCenter()
    _ = try await center.addDevelopmentFolder(folder, window: nil)
    let host = FakeToolSessionHost()
    let session = try open("com.example.list/find", in: center, host: host, text: "a")
    defer { session.teardown() }
    #expect(await waitForToolCondition { session.primaryResultText == "v-a" })
    session.updateQuery("b")
    #expect(await waitForToolCondition { session.primaryResultText == "v-b" })
  }

  @Test func noneScriptReportsCompletionAndRequestsClose() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let feature: [String: Any] = [
      "code": "touch", "title": "Touch", "keywords": ["touch"],
      "action": ["type": "script", "command": ["/usr/bin/true"], "output": "none"],
    ]
    let folder = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("none"), id: "com.example.none", features: [feature])
    let center = sandbox.makeCenter()
    _ = try await center.addDevelopmentFolder(folder, window: nil)
    let host = FakeToolSessionHost()
    let session = try open("com.example.none/touch", in: center, host: host)
    defer { session.teardown() }
    #expect(await waitForToolCondition { host.closeRequests == 1 })
    #expect(host.notices.contains { $0.text == L("已完成") && !$0.isError })
  }

  @Test func terminalScriptIsHandedToHost() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let feature: [String: Any] = [
      "code": "shell", "title": "Shell", "keywords": ["shell"],
      "action": ["type": "script", "command": ["bin/run.sh", "--flag"], "output": "terminal"],
    ]
    let folder = try writeToolPlugin(
      at: sandbox.external.appendingPathComponent("term"), id: "com.example.term", features: [feature],
      files: ["bin/run.sh": "#!/bin/sh\necho hi\n"])
    try makeExecutable(folder.appendingPathComponent("bin/run.sh"))
    let center = sandbox.makeCenter()
    _ = try await center.addDevelopmentFolder(folder, window: nil)
    let host = FakeToolSessionHost()
    let session = try open("com.example.term/shell", in: center, host: host)
    defer { session.teardown() }
    #expect(await waitForToolCondition { host.closeRequests == 1 })
    let run = try #require(host.terminalRuns.first)
    #expect(run.command == [canonicalToolPath(folder.appendingPathComponent("bin/run.sh")), "--flag"])
    #expect(run.environment["ASTER_PLUGIN_ID"] == "com.example.term")
    #expect(run.environment["PATH"] == nil)
  }

  @Test func disabledPluginShowsMessageAndRecoversWhenEnabled() async throws {
    let sandbox = try ToolRuntimeSandbox()
    defer { sandbox.cleanup() }
    let folder = try writeToolPlugin(at: sandbox.external.appendingPathComponent("echo"), id: "com.example.echo")
    let center = sandbox.makeCenter()
    _ = try await center.addDevelopmentFolder(folder, window: nil)
    let entry = try #require(center.entry(id: "com.example.echo/run"))
    center.setEnabled(false, pluginID: "com.example.echo")
    let host = FakeToolSessionHost()
    let session = center.makeSession(
      for: ToolLaunchRequest(entry: entry, input: ToolInput(), origin: nil), host: host)
    _ = session.view
    defer { session.teardown() }
    #expect(session.primaryResultText == nil)

    center.setEnabled(true, pluginID: "com.example.echo")
    #expect(await waitForToolCondition { session.primaryResultText == "hi" })
  }
}
