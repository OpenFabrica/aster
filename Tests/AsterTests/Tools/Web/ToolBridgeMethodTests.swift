// 桥接方法：存储配额与 key 上限、files.read 允许列表、界面高度与关闭、终端预填、外部链接确认与通知。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 建一个桥接，返回它与假系统能力、假代理和插件目录。
@MainActor
private func makeBridge(
  permissions: [ToolPermission] = [],
  request: ToolLaunchRequest = makeWebToolRequest()
) throws -> (ToolBridge, FakeToolBridgeServices, FakeToolBridgeDelegate, URL) {
  let directory = try makeTemporaryPluginDirectory()
  let services = FakeToolBridgeServices()
  let bridge = ToolBridge(
    plugin: makeWebToolPlugin(directory: directory, permissions: permissions), services: services)
  let delegate = FakeToolBridgeDelegate(request: request)
  bridge.delegate = delegate
  return (bridge, services, delegate, directory)
}

@Test("存储读写删与 keys，值保持 JSON 结构并落盘到 storage.json")
@MainActor
func toolBridgeStorageRoundTrip() async throws {
  let (bridge, _, _, directory) = try makeBridge()
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(await callBridge(bridge, "storage.get", ["key": "missing"]).json == "null")
  #expect(await callBridge(bridge, "storage.set", ["key": "b", "value": ["n": 1, "list": [true, "x"]]]).error == nil)
  #expect(await callBridge(bridge, "storage.set", ["key": "a", "value": "text"]).error == nil)
  #expect(await callBridge(bridge, "storage.get", ["key": "b"]).json == #"{"list":[true,"x"],"n":1}"#)
  #expect(await callBridge(bridge, "storage.keys").json == #"["a","b"]"#)
  #expect(await callBridge(bridge, "storage.remove", ["key": "a"]).error == nil)
  #expect(await callBridge(bridge, "storage.keys").json == #"["b"]"#)

  let file = directory.appendingPathComponent("data/storage.json")
  let stored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
  #expect(stored == ["b": ["list": [true, "x"], "n": 1]])
}

@Test("key 超过 128 字节或为空被拒；超过 5 MiB 总量的写入被拒且原内容不变")
@MainActor
func toolBridgeStorageEnforcesLimits() async throws {
  let (bridge, _, _, directory) = try makeBridge()
  defer { try? FileManager.default.removeItem(at: directory) }

  let longKey = String(repeating: "k", count: ToolBridgeProtocol.maximumStorageKeyBytes + 1)
  #expect(await callBridge(bridge, "storage.set", ["key": longKey, "value": 1]).errorCode == "payload_too_large")
  #expect(await callBridge(bridge, "storage.set", ["key": "", "value": 1]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "storage.set", ["key": "novalue"]).errorCode == "invalid_params")

  // 单条消息上限 2 MiB，所以分三次各写约 1.9 MiB，第三次让总量越过 5 MiB。
  let chunk = String(repeating: "x", count: 1_900_000)
  #expect(await callBridge(bridge, "storage.set", ["key": "one", "value": chunk]).error == nil)
  #expect(await callBridge(bridge, "storage.set", ["key": "two", "value": chunk]).error == nil)
  #expect(await callBridge(bridge, "storage.set", ["key": "three", "value": chunk]).errorCode == "payload_too_large")
  #expect(await callBridge(bridge, "storage.keys").json == #"["one","two"]"#)
}

@Test("files.read 只认当前输入里的文件与本会话 files.pick 选中的文件")
@MainActor
func toolBridgeFilesReadUsesSessionAllowList() async throws {
  let files = try makeTemporaryPluginDirectory(files: ["input.txt": "from input", "picked.txt": "picked", "other.txt": "no"])
  defer { try? FileManager.default.removeItem(at: files) }
  let inputPath = files.appendingPathComponent("input.txt").path
  // 桥接只弱引用代理，输入文件列表在代理的请求里，所以这里要持有它。
  let (bridge, services, delegate, directory) = try makeBridge(
    permissions: [.filesRead], request: makeWebToolRequest(files: [inputPath]))
  defer {
    withExtendedLifetime(delegate) {}
    try? FileManager.default.removeItem(at: directory)
  }

  #expect(await callBridge(bridge, "files.read", ["path": inputPath]).json == #""from input""#)
  let otherPath = files.appendingPathComponent("other.txt").path
  #expect(await callBridge(bridge, "files.read", ["path": otherPath]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "files.read", ["path": "relative.txt"]).errorCode == "invalid_params")

  let pickedPath = files.appendingPathComponent("picked.txt").path
  #expect(await callBridge(bridge, "files.read", ["path": pickedPath]).errorCode == "invalid_params")
  services.pickResult = [URL(fileURLWithPath: pickedPath)]
  let picked = await callBridge(bridge, "files.pick", ["extensions": [".TXT"], "multiple": true])
  #expect(picked.json == "[\"\(ToolFileReader.normalizedPath(pickedPath) ?? "")\"]")
  #expect(services.pickRequests.first?.extensions == ["txt"])
  #expect(services.pickRequests.first?.multiple == true)
  // 允许列表按规范化路径比对，多余的 `/./` 不影响。
  let dotted = files.path + "/./picked.txt"
  #expect(await callBridge(bridge, "files.read", ["path": dotted, "encoding": "base64"]).json == #""cGlja2Vk""#)
  #expect(await callBridge(bridge, "files.read", ["path": pickedPath, "encoding": "latin1"]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "files.pick", ["extensions": ["../x"]]).errorCode == "invalid_params")
}

@Test("tool.input 给出 code、输入与环境；ui.setHeight 夹到 120–800；ui.close 先回复再请求关闭")
@MainActor
func toolBridgeInputHeightAndClose() async throws {
  let (bridge, _, delegate, directory) = try makeBridge(request: makeWebToolRequest(text: "eyJhbGciOi"))
  defer { try? FileManager.default.removeItem(at: directory) }

  let input = await callBridge(bridge, "tool.input")
  let payload = try JSONDecoder().decode(JSONValue.self, from: Data((input.json ?? "").utf8))
  #expect(payload["code"] == "main")
  #expect(payload["input"]?["text"] == "eyJhbGciOi")
  #expect(payload["input"]?["source"] == "typed")
  #expect(payload["context"]?["appearance"] == "light")

  _ = await callBridge(bridge, "ui.setHeight", ["height": 2_000])
  _ = await callBridge(bridge, "ui.setHeight", ["height": 10])
  _ = await callBridge(bridge, "ui.setHeight", ["height": 333.4])
  #expect(delegate.heights == [800, 120, 333])
  #expect(await callBridge(bridge, "ui.setHeight", ["height": "tall"]).errorCode == "invalid_params")

  #expect(await callBridge(bridge, "ui.close").json == "null")
  #expect(delegate.closeCount == 1)
}

@Test("terminal.insert 把宿主给的失败原因回给页面；terminal.selection 读来源选区")
@MainActor
func toolBridgeTerminalMethods() async throws {
  let (bridge, _, delegate, directory) = try makeBridge(permissions: [.terminalInsert, .terminalRead])
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(await callBridge(bridge, "terminal.insert", ["text": "ls -la"]).error == nil)
  delegate.insertFailure = "来源终端已经关闭"
  #expect(await callBridge(bridge, "terminal.insert", ["text": "pwd"]).error == "unavailable: 来源终端已经关闭")
  #expect(delegate.insertedTexts == ["ls -la", "pwd"])

  #expect(await callBridge(bridge, "terminal.selection").json == "null")
  delegate.selection = "selected"
  #expect(await callBridge(bridge, "terminal.selection").json == #""selected""#)
}

@Test("shell.openURL 只允许 http(s)，用户同意后才交给浏览器；notify 清理控制字符并带上插件名")
@MainActor
func toolBridgeOpenURLAndNotify() async throws {
  let (bridge, services, _, directory) = try makeBridge(permissions: [.notify])
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(await callBridge(bridge, "shell.openURL", ["url": "javascript:alert(1)"]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "shell.openURL", ["url": "file:///etc/passwd"]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "shell.openURL", ["url": "https://example.com/a"]).json == "false")
  #expect(services.openedURLs.isEmpty)
  services.confirmResult = true
  #expect(await callBridge(bridge, "shell.openURL", ["url": "https://example.com/a"]).json == "true")
  #expect(services.openedURLs == [URL(string: "https://example.com/a")])

  #expect(await callBridge(bridge, "notify", ["title": "完成\u{7}\n了", "body": "第一行\n第二行\u{1b}"]).error == nil)
  #expect(services.notifications.first?.title == "完成  了")
  #expect(services.notifications.first?.body == "第一行\n第二行 ")
  #expect(services.notifications.first?.pluginName == "网页测试")
  #expect(await callBridge(bridge, "notify", ["title": "  "]).errorCode == "invalid_params")
  let longTitle = String(repeating: "长", count: ToolBridge.maximumNotificationTitleLength + 1)
  #expect(await callBridge(bridge, "notify", ["title": longTitle]).errorCode == "payload_too_large")
}
