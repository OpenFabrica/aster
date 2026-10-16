// 其它入口（标签菜单「编辑主机…」、Open Quickly、新建工作区「添加主机…」）请求主机页编辑面板：
// `AppModel.showHostEditor` 记下请求并显示主机页，主机页在 `pageDidAppear` 消费它。
import AppKit
import Combine
import Testing

@testable import Aster
@testable import AsterCore

@Test("编辑请求：从别的子页切回「主机」子页，显示主机页并打开该主机的编辑面板")
@MainActor
func showHostEditorPresentsPageAndOpensEditor() throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture)
  defer { window.orderOut(nil) }
  let model = page.model
  let hub = try #require(page.parent as? HostsHubViewController)
  model.hostsPageSection = .keys

  model.showHostEditor(hostID: fixture.full.id)
  #expect(model.isHostsPagePresented)
  #expect(model.hostsPageSection == .hosts)
  #expect(model.pendingHostEditor == .edit(fixture.full.id))

  // 工作区刷新内容区时调用外壳的 pageDidAppear；外壳同步子页后转给主机页消费请求。
  hub.pageDidAppear()
  #expect(hub.section == .hosts)
  #expect(page.editorPanel?.mode == .edit(fixture.full.id))
  #expect(model.pendingHostEditor == nil)
  // 请求只消费一次：再次出现不会重开或替换面板。
  let panel = page.editorPanel
  page.pageDidAppear()
  #expect(page.editorPanel === panel)
}

@Test("编辑请求：主机页已显示时也发出变化，让工作区刷新并消费请求")
@MainActor
func showHostEditorNotifiesWhenPageAlreadyPresented() throws {
  let defaults = try #require(UserDefaults(suiteName: "HostEditorRequest.\(UUID().uuidString)"))
  let model = AppModel(defaults: defaults)
  model.presentHostsPage(section: .hosts)
  var changes = 0
  let subscription = model.objectWillChange.sink { _ in changes += 1 }
  defer { subscription.cancel() }

  model.showHostEditor(.defaults)
  #expect(changes > 0)
  #expect(model.pendingHostEditor == .defaults)
}

@Test("编辑请求：主机已不存在时不开面板，主机页停在列表并提示")
@MainActor
func showHostEditorForMissingHostStaysOnList() throws {
  let fixture = try HostEditorFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (page, window) = try makeEditorWindow(fixture)
  defer { window.orderOut(nil) }
  let model = page.model

  model.showHostEditor(hostID: UUID())
  page.pageDidAppear()
  #expect(page.editorPanel == nil)
  #expect(model.pendingHostEditor == nil)
  #expect(model.notice == L("主机不存在，可能已被删除"))
  #expect(model.isHostsPagePresented)
}
