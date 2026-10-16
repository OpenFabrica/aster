// 设置页「主机」分类只剩 Agent 访问：快照只有 `agentAccess`，动作只认 Agent 访问与「打开主机页」。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 用临时 hosts.json 与空运行时建协作者，不读写用户真实配置。
@MainActor
private func makeBridge() -> (SettingsAgentAccessBridge, URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterSettingsAgentAccess-\(UUID().uuidString)", isDirectory: true)
  let directory = SSHHostDirectory(store: SSHHostStore(fileURL: root.appendingPathComponent("hosts.json")))
  let bridge = SettingsAgentAccessBridge(hosts: directory)
  bridge.runtime = { nil }
  return (bridge, root)
}

@Test("设置主机快照：只有 agentAccess，不再带主机列表、密钥或已知主机")
@MainActor
func settingsHostsSnapshotOnlyHasAgentAccess() throws {
  let (bridge, root) = makeBridge()
  defer { try? FileManager.default.removeItem(at: root) }
  let snapshot = bridge.snapshot()
  #expect(Set(snapshot.keys) == ["agentAccess"])
  let agent = try #require(snapshot["agentAccess"] as? [String: Any])
  #expect(agent["available"] as? Bool == false)
  #expect(agent["enabled"] as? Bool == false)
}

@Test("设置主机动作：hosts.openHostsPage 打开主机页，不依赖 agent 运行时")
@MainActor
func settingsOpenHostsPageAction() throws {
  let (bridge, root) = makeBridge()
  defer { try? FileManager.default.removeItem(at: root) }
  var opened = 0
  var toasts: [String] = []
  bridge.openHostsPage = { opened += 1 }
  bridge.toast = { text, _ in toasts.append(text) }
  var result: Bool?
  bridge.handle(action: "hosts.openHostsPage", payload: [:]) { result = $0 }
  #expect(result == true)
  #expect(opened == 1)
  #expect(toasts.isEmpty)
}

@Test("设置主机动作：已移走的主机编辑动作按未知动作拒绝")
@MainActor
func settingsRemovedHostActionsAreRejected() throws {
  let (bridge, root) = makeBridge()
  defer { try? FileManager.default.removeItem(at: root) }
  var toasts: [(String, Bool)] = []
  bridge.toast = { toasts.append(($0, $1)) }
  for action in ["hosts.save", "hosts.delete", "hosts.keys.generate", "hosts.knownHosts.remove"] {
    var result: Bool?
    bridge.handle(action: action, payload: [:]) { result = $0 }
    #expect(result == false)
  }
  #expect(toasts.count == 4 && toasts.allSatisfy(\.1))
}
