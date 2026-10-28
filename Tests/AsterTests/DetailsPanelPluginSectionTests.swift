// Inspector 插件页签：chip 出现与会话借用复用、页签消失时回落与恢复、与内置页的选中态互斥。
import AppKit
import AsterCore
import Combine
import Foundation
import Testing

@testable import Aster

/// 假的窗口插件提供方：条目可改，会话按条目懒建一次并记下借用次数。
@MainActor
private final class FakePanelProvider: ToolPanelProviding {
  var inspectorPanelEntries: [ToolViewEntry] = []
  private let changes = PassthroughSubject<Void, Never>()
  private let center: ToolCenter
  private let host = FakeToolSessionHost()
  private(set) var sessions: [String: ToolSessionViewController] = [:]
  private(set) var lendCount = 0

  init(center: ToolCenter) {
    self.center = center
  }

  var panelEntriesChanged: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

  /// 改条目并通知。
  func setEntries(_ entries: [ToolViewEntry]) {
    inspectorPanelEntries = entries
    changes.send()
  }

  /// 第一次借时建会话（用轻量的内置 UUID 工具承载），之后复用。
  func panelSession(for entryID: String) -> ToolSessionViewController? {
    guard inspectorPanelEntries.contains(where: { $0.id == entryID }) else { return nil }
    lendCount += 1
    if let existing = sessions[entryID] { return existing }
    guard let builtin = center.entry(id: "aster.builtin/uuid") else { return nil }
    let session = center.makeSession(
      for: ToolLaunchRequest(entry: builtin, input: ToolInput(), origin: nil), host: host)
    sessions[entryID] = session
    return session
  }
}

@MainActor
private func pluginPanelEntry(viewID: String = "status", title: String = "Git 状态") -> ToolViewEntry {
  ToolViewEntry(
    pluginID: "com.example.panel", pluginName: "Panel", source: .development,
    contribution: ToolViewContribution(
      id: viewID, title: title, kind: .panel, slot: .inspectorPanel, main: "views/status.html"),
    slot: .inspectorPanel, isEnabled: true, status: .ready, iconPath: nil, pluginDirectory: nil, permissions: [])
}

/// 隔离的偏好、模型与工具中心。
@MainActor
private struct PluginPanelFixture {
  let defaults: UserDefaults
  let preferences: AppPreferences
  let model: AppModel
  let sandbox: ToolRuntimeSandbox
  let provider: FakePanelProvider

  init() throws {
    _ = NSApplication.shared
    let suite = "DetailsPanelPluginSectionTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    preferences = AppPreferences(defaults: defaults)
    model = AppModel(defaults: defaults)
    sandbox = try ToolRuntimeSandbox()
    provider = FakePanelProvider(center: sandbox.makeCenter())
  }

  /// 注入提供方并加载视图的详情面板。
  func makeController() -> DetailsPanelViewController {
    let controller = DetailsPanelViewController(model: model, preferences: preferences)
    controller.pluginPanels = provider
    controller.loadViewIfNeeded()
    return controller
  }

  func cleanup() {
    for session in provider.sessions.values { session.teardown() }
    sandbox.cleanup()
  }
}

/// 按 identifier 在视图树里找 chip。
@MainActor
private func chip(_ identifier: String, in controller: DetailsPanelViewController) -> NSButton? {
  /// 深度优先查找。
  func find(in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
    for subview in view.subviews {
      if let match = find(in: subview) { return match }
    }
    return nil
  }
  return find(in: controller.view)
}

/// chip 是否处于选中（展开）态：宽度约束在选中时立即写成展开宽度（> 收起宽度 26）。
@MainActor
private func isExpanded(_ button: NSButton?) -> Bool {
  guard let button else { return false }
  let width = button.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil }
  return (width?.constant ?? 0) > 26
}

@Test("插件页签：注入后出现 chip，选中时借窗口的会话挂进内容区；切走只摘下，再选回复用同一会话")
@MainActor
func inspectorPluginChipAppearsAndReusesSession() throws {
  let fixture = try PluginPanelFixture()
  defer { fixture.cleanup() }
  let entry = pluginPanelEntry()
  fixture.provider.setEntries([entry])
  let controller = fixture.makeController()
  let chipID = "details-chip-plugin-\(entry.id)"
  let pluginChip = try #require(chip(chipID, in: controller))
  #expect(fixture.provider.lendCount == 0, "没选中时不借会话")

  pluginChip.performClick(nil)
  let session = try #require(fixture.provider.sessions[entry.id])
  #expect(session.view.isDescendant(of: controller.view))
  #expect(session.parent === controller)
  #expect(fixture.preferences.inspectorPluginSection == entry.id)
  #expect(isExpanded(chip(chipID, in: controller)))

  // 切到内置页：会话只从视图树摘下，没有 teardown（内容还在）。
  try #require(chip("details-chip-git", in: controller)).performClick(nil)
  #expect(session.view.superview == nil)
  #expect(session.parent == nil)
  #expect(!session.view.subviews.isEmpty)

  try #require(chip(chipID, in: controller)).performClick(nil)
  #expect(fixture.provider.sessions.count == 1)
  #expect(session.view.isDescendant(of: controller.view))

  // 换标签时窗口新建详情面板：恢复上次选中的插件页签，同一会话移到新面板。
  let next = fixture.makeController()
  #expect(session.view.isDescendant(of: next.view))
  #expect(session.parent === next)
  #expect(!session.view.isDescendant(of: controller.view))
  #expect(isExpanded(chip(chipID, in: next)))
}

@Test("插件页签消失时回落到内置页并摘下会话；记住的选择在页签回来后恢复")
@MainActor
func pluginSelectionFallsBackWhenEntryDisappears() throws {
  let fixture = try PluginPanelFixture()
  defer { fixture.cleanup() }
  let entry = pluginPanelEntry()
  fixture.provider.setEntries([entry])
  let controller = fixture.makeController()
  let chipID = "details-chip-plugin-\(entry.id)"
  try #require(chip(chipID, in: controller)).performClick(nil)
  let session = try #require(fixture.provider.sessions[entry.id])

  fixture.provider.setEntries([])
  #expect(chip(chipID, in: controller) == nil)
  #expect(isExpanded(chip("details-chip-info", in: controller)))
  #expect(session.view.superview == nil)
  // 插件目录启动后才扫描完：回落不清掉记住的选择。
  #expect(fixture.preferences.inspectorPluginSection == entry.id)

  fixture.provider.setEntries([entry])
  #expect(isExpanded(chip(chipID, in: controller)))
  #expect(!isExpanded(chip("details-chip-info", in: controller)))
  #expect(session.view.isDescendant(of: controller.view))
}

@Test("选中插件页签清掉内置与自定义视图的选中；再选内置页清掉插件选择")
@MainActor
func selectingPluginChipClearsBuiltinSelection() throws {
  let fixture = try PluginPanelFixture()
  defer { fixture.cleanup() }
  fixture.preferences.inspectorSection = 2
  let entry = pluginPanelEntry()
  fixture.provider.setEntries([entry])
  let controller = fixture.makeController()
  #expect(isExpanded(chip("details-chip-git", in: controller)))
  // 互斥：选中插件页签时自定义视图的持久化选择也要清掉。
  fixture.preferences.inspectorCustomSection = UUID()

  controller.selectPluginPanel(entryID: entry.id)
  #expect(!isExpanded(chip("details-chip-git", in: controller)))
  #expect(isExpanded(chip("details-chip-plugin-\(entry.id)", in: controller)))
  #expect(fixture.preferences.inspectorCustomSection == nil)
  #expect(fixture.preferences.inspectorPluginSection == entry.id)

  // 不存在的页签什么都不做。
  controller.selectPluginPanel(entryID: "com.example.none/view:x")
  #expect(fixture.preferences.inspectorPluginSection == entry.id)

  try #require(chip("details-chip-files", in: controller)).performClick(nil)
  #expect(fixture.preferences.inspectorPluginSection == nil)
  #expect(fixture.preferences.inspectorSection == 3)
  #expect(!isExpanded(chip("details-chip-plugin-\(entry.id)", in: controller)))
  #expect(fixture.provider.sessions[entry.id]?.view.superview == nil)
}
