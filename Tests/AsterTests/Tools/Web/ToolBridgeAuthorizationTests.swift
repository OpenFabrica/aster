// 桥接的授权与协议边界：未声明 / 未授予的权限被拒、限流、协议版本与消息格式、失效后的调用。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 建一个桥接：插件目录在临时目录里，系统能力与代理都是假的。
@MainActor
private func makeBridge(
  permissions: [ToolPermission] = [],
  granted: Set<ToolPermission>? = nil,
  clock: ManualClock? = nil
) throws -> (ToolBridge, FakeToolBridgeServices, FakeToolBridgeDelegate) {
  let directory = try makeTemporaryPluginDirectory()
  let services = FakeToolBridgeServices()
  let plugin = makeWebToolPlugin(directory: directory, permissions: permissions, granted: granted)
  let bridge =
    if let clock {
      ToolBridge(plugin: plugin, services: services, clock: { clock.now })
    } else {
      ToolBridge(plugin: plugin, services: services)
    }
  let delegate = FakeToolBridgeDelegate(request: makeWebToolRequest())
  bridge.delegate = delegate
  return (bridge, services, delegate)
}

@Test("没声明权限的方法一律 permission_denied，系统能力不被调用")
@MainActor
func toolBridgeRejectsUndeclaredPermissions() async throws {
  let (bridge, services, delegate) = try makeBridge()
  services.clipboard = "secret"

  let cases: [(String, [String: Any])] = [
    ("clipboard.writeText", ["text": "x"]),
    ("clipboard.readText", [:]),
    ("terminal.insert", ["text": "ls"]),
    ("terminal.selection", [:]),
    ("files.pick", [:]),
    ("files.read", ["path": "/etc/hosts"]),
    ("net.fetch", ["url": "https://example.com"]),
    ("notify", ["title": "hi"]),
  ]
  for (method, params) in cases {
    let reply = await callBridge(bridge, method, params)
    #expect(reply.errorCode == "permission_denied", "\(method)")
  }
  #expect(services.clipboard == "secret")
  #expect(services.pickRequests.isEmpty)
  #expect(services.notifications.isEmpty)
  #expect(delegate.insertedTexts.isEmpty)
}

@Test("清单声明但用户没授予、或授予了但清单已不再声明的权限都不可用")
@MainActor
func toolBridgeUsesGrantedAndDeclaredPermissionsOnly() async throws {
  let (notGranted, _, _) = try makeBridge(permissions: [.clipboardWrite], granted: [])
  #expect(await callBridge(notGranted, "clipboard.writeText", ["text": "x"]).errorCode == "permission_denied")

  let (notDeclared, _, _) = try makeBridge(permissions: [], granted: [.clipboardWrite])
  #expect(await callBridge(notDeclared, "clipboard.writeText", ["text": "x"]).errorCode == "permission_denied")

  let (allowed, services, _) = try makeBridge(permissions: [.clipboardWrite])
  let reply = await callBridge(allowed, "clipboard.writeText", ["text": "copied"])
  #expect(reply.error == nil)
  #expect(reply.json == "null")
  #expect(services.clipboard == "copied")
}

@Test("每秒最多 50 次调用，第 51 次 rate_limited，一秒后恢复")
@MainActor
func toolBridgeRateLimitsCallsPerSecond() async throws {
  let clock = ManualClock()
  // 桥接只弱引用代理，tool.input 要读代理里的请求，所以这里要持有它。
  let (bridge, _, delegate) = try makeBridge(clock: clock)
  defer { withExtendedLifetime(delegate) {} }
  var errors: [String?] = []
  for _ in 0..<50 {
    errors.append(await callBridge(bridge, "tool.input").errorCode)
    clock.now += 0.001
  }
  #expect(errors.allSatisfy { $0 == nil })
  #expect(await callBridge(bridge, "tool.input").errorCode == "rate_limited")
  // 格式不对的消息同样计入限流，不会被反复解析。
  #expect(await callBridge(bridge, "no.such.method").errorCode == "rate_limited")

  clock.now += 1
  #expect(await callBridge(bridge, "tool.input").errorCode == nil)
}

@Test("协议版本、未知方法与参数结构不合格分别报错")
@MainActor
func toolBridgeRejectsMalformedMessages() async throws {
  let (bridge, _, _) = try makeBridge()
  let wrongVersion = await withCheckedContinuation { continuation in
    bridge.handle(body: ["v": 2, "method": "tool.input"]) { value, error in
      continuation.resume(returning: BridgeReply(value: value, error: error))
    }
  }
  #expect(wrongVersion.errorCode == "unsupported_version")
  #expect(await callBridge(bridge, "system.exec").errorCode == "unknown_method")
  let badParams = await withCheckedContinuation { continuation in
    bridge.handle(body: ["v": 1, "method": "storage.get", "params": [1, 2]]) { value, error in
      continuation.resume(returning: BridgeReply(value: value, error: error))
    }
  }
  #expect(badParams.errorCode == "invalid_params")
}

@Test("失效后的调用回 unavailable，不再回调代理，并收起对话框")
@MainActor
func toolBridgeStopsAfterInvalidation() async throws {
  let (bridge, services, delegate) = try makeBridge()
  bridge.invalidate()
  #expect(await callBridge(bridge, "ui.setHeight", ["height": 300]).errorCode == "unavailable")
  #expect(await callBridge(bridge, "ui.close").errorCode == "unavailable")
  #expect(delegate.heights.isEmpty)
  #expect(delegate.closeCount == 0)
  #expect(services.dismissCount == 1)
}
