// 从主机页连出去的 SSH 标签在会话结束、自动关闭后回到主机页；其它标签不受影响。
import Foundation
import Testing

@testable import Aster

/// 建一个隔离偏好的 AppModel，并确保至少有两个标签。
@MainActor
private func makeModel() throws -> (AppModel, UserDefaults, String) {
  let suiteName = "HostsPageReturnAfterSSHExitTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  model.newTab(hasContent: true)
  return (model, defaults, suiteName)
}

@Test @MainActor func sshTabFromHostsPageReturnsToHostsPageAfterExit() throws {
  let (model, defaults, suite) = try makeModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let tab = try #require(model.selectedTab)
  let pane = try #require(tab.layout.allPanes.first)
  model.hostsPageOriginTabIDs.insert(tab.id)

  model.closePaneAfterShellExit(paneID: pane.id, in: tab)

  #expect(!model.tabs.contains { $0 === tab })
  #expect(model.isHostsPagePresented)
  #expect(!model.hostsPageOriginTabIDs.contains(tab.id))
}

@Test @MainActor func otherTabsStayInTerminalAfterExit() throws {
  let (model, defaults, suite) = try makeModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let tab = try #require(model.selectedTab)
  let pane = try #require(tab.layout.allPanes.first)

  model.closePaneAfterShellExit(paneID: pane.id, in: tab)

  #expect(!model.tabs.contains { $0 === tab })
  #expect(!model.isHostsPagePresented)
}
