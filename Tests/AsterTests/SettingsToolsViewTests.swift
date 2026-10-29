// 设置页「工具」分类的视图控制：快照里的视图行与挂载点、setViewEnabled / setViewSlot 的参数校验。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 带一个 bar 视图与一个 panel 视图的插件，供视图相关测试共用。
@MainActor
private func makeViewTools() -> FakeToolCenter {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [
    toolSummary(
      "com.example.views", name: "视图插件",
      views: [
        toolViewSummary("branch"),
        toolViewSummary(
          "status", title: "Git 状态", kind: .panel, slot: .inspectorPanel, defaultSlot: .inspectorPanel),
        toolViewSummary(
          "future", title: "未来", slot: .paneHeader, defaultSlot: .paneHeader, inactiveReason: .unsupported),
      ])
  ]
  return tools
}

@Test("工具快照：插件行带视图列表，顶层带挂载点一览")
@MainActor
func snapshotIncludesViewRowsAndSlots() throws {
  let (bridge, _) = makeToolsBridge(makeViewTools())
  let snapshot = bridge.snapshot()

  let plugin = try #require((snapshot["plugins"] as? [[String: Any]])?.first)
  let views = try #require(plugin["views"] as? [[String: Any]])
  #expect(views.compactMap { $0["id"] as? String } == ["branch", "status", "future"])
  let branch = views[0]
  #expect(Set(branch.keys) == ["id", "title", "kind", "slot", "defaultSlot", "enabled", "slots", "inactiveReason"])
  #expect(branch["kind"] as? String == "bar")
  #expect(branch["slot"] as? String == "tab.bottom")
  #expect(branch["defaultSlot"] as? String == "tab.bottom")
  #expect(branch["enabled"] as? Bool == true)
  #expect(branch["inactiveReason"] is NSNull)
  // 可选位置只含本版本已实现且接受该类型的挂载点。
  #expect(branch["slots"] as? [String] == ["window.top", "window.bottom", "sidebar.section", "tab.top", "tab.bottom", "pane.header", "pane.bottom", "activePane.bottom"])
  #expect(views[1]["slots"] as? [String] == ["sidebar.section", "inspector.panel"])
  #expect(views[2]["inactiveReason"] as? String == "unsupported")

  let slots = try #require(snapshot["viewSlots"] as? [[String: Any]])
  #expect(slots.compactMap { $0["id"] as? String } == ToolViewSlot.allCases.map(\.rawValue))
  let bottom = try #require(slots.first { $0["id"] as? String == "tab.bottom" })
  #expect(bottom["title"] as? String == L("标签底部"))
  #expect(bottom["kinds"] as? [String] == ["bar"])
  #expect(bottom["implemented"] as? Bool == true)
  let paneHeader = try #require(slots.first { $0["id"] as? String == "pane.header" })
  #expect(paneHeader["implemented"] as? Bool == true)
  #expect(JSONSerialization.isValidJSONObject(snapshot))
}

@Test("视图动作：setViewSlot 拒绝类型不符与未知的位置")
@MainActor
func setViewSlotRejectsIncompatibleKind() async {
  let tools = makeViewTools()
  let (bridge, recorder) = makeToolsBridge(tools)
  let base: [String: Any] = ["id": "com.example.views", "view": "branch"]

  // panel 的位置不接受 bar；其余是未知字符串或错误类型。
  for slot: Any in ["inspector.panel", "nowhere", 7] {
    #expect(await performToolsAction(bridge, "tools.setViewSlot", base.merging(["slot": slot]) { $1 }) == false)
  }
  // 不存在的视图与缺少 view 参数。
  #expect(await performToolsAction(bridge, "tools.setViewSlot", ["id": "com.example.views", "view": "none", "slot": "tab.top"]) == false)
  #expect(await performToolsAction(bridge, "tools.setViewSlot", ["id": "com.example.views", "slot": "tab.top"]) == false)
  #expect(tools.viewSlotCalls.isEmpty)
  #expect(recorder.toasts.count == 5 && recorder.toasts.allSatisfy { $0.isError })

  // 兼容的位置放行。
  #expect(await performToolsAction(bridge, "tools.setViewSlot", base.merging(["slot": "tab.top"]) { $1 }))
  #expect(tools.viewSlotCalls.count == 1)
  #expect(tools.viewSlotCalls[0].id == "com.example.views" && tools.viewSlotCalls[0].view == "branch")
  #expect(tools.viewSlotCalls[0].slot == .tabTop)
}

@Test("视图动作：setViewSlot 传 null 恢复清单缺省")
@MainActor
func setViewSlotNullRestoresDefault() async {
  let tools = makeViewTools()
  let (bridge, recorder) = makeToolsBridge(tools)
  #expect(await performToolsAction(bridge, "tools.setViewSlot", ["id": "com.example.views", "view": "branch", "slot": NSNull()]))
  #expect(tools.viewSlotCalls.count == 1)
  #expect(tools.viewSlotCalls[0].slot == nil)
  // 省略 slot 键等价于 null。
  #expect(await performToolsAction(bridge, "tools.setViewSlot", ["id": "com.example.views", "view": "branch"]))
  #expect(tools.viewSlotCalls.count == 2 && tools.viewSlotCalls[1].slot == nil)
  #expect(recorder.pushes == 2)
}

@Test("视图动作：setViewEnabled 只认 JSON 布尔值与该插件的视图")
@MainActor
func setViewEnabledUsesStrictBool() async {
  let tools = makeViewTools()
  let (bridge, recorder) = makeToolsBridge(tools)
  let base: [String: Any] = ["id": "com.example.views", "view": "branch"]

  #expect(await performToolsAction(bridge, "tools.setViewEnabled", base.merging(["enabled": false]) { $1 }))
  #expect(tools.viewEnabledCalls.count == 1)
  #expect(tools.viewEnabledCalls[0].view == "branch" && tools.viewEnabledCalls[0].enabled == false)
  #expect(recorder.pushes == 1)

  // 数字 0 / 1、字符串、缺参数都不算布尔。
  for value: Any? in [1, 0, "true", nil] {
    var payload = base
    payload["enabled"] = value
    #expect(await performToolsAction(bridge, "tools.setViewEnabled", payload) == false)
  }
  #expect(await performToolsAction(bridge, "tools.setViewEnabled", ["id": "com.example.views", "view": "none", "enabled": true]) == false)
  #expect(await performToolsAction(bridge, "tools.setViewEnabled", ["id": "com.example.none", "view": "branch", "enabled": true]) == false)
  #expect(tools.viewEnabledCalls.count == 1)
  #expect(recorder.toasts.count == 6 && recorder.toasts.allSatisfy { $0.isError })
}

@Test("工具快照：标签栏不是竖排或被关掉时，正在生效的侧栏视图标成 layout；改回竖排推一份新快照")
@MainActor
func snapshotMarksSidebarViewsInactiveInHorizontalLayout() async throws {
  let tools = FakeToolCenter()
  tools.pluginSummaries = [
    toolSummary(
      "com.example.side", name: "侧栏插件",
      views: [
        toolViewSummary("list", slot: .sidebarSection),
        toolViewSummary(
          "notes", title: "便笺", kind: .panel, slot: .sidebarSection, defaultSlot: .sidebarSection),
        toolViewSummary("off", slot: .sidebarSection, enabled: false, inactiveReason: .disabled),
        toolViewSummary("branch"),
      ])
  ]
  let preferences = isolatedToolsPreferences()
  let (bridge, recorder) = makeToolsBridge(tools, preferences: preferences)
  bridge.start()
  func reasons() throws -> [String] {
    let plugin = try #require((bridge.snapshot()["plugins"] as? [[String: Any]])?.first)
    let views = try #require(plugin["views"] as? [[String: Any]])
    return views.map { $0["inactiveReason"] as? String ?? "-" }
  }
  // 竖排（缺省）：侧栏视图正在生效。
  #expect(try reasons() == ["-", "-", "disabled", "-"])

  preferences.tabBarLayout = .top
  #expect(try reasons() == ["layout", "layout", "disabled", "-"])
  await drainToolsMainQueue()
  #expect(recorder.pushes == 1, "布局变化推一份新快照")

  preferences.tabBarLayout = .vertical
  var configuration = preferences.configuration
  configuration.appearance.showTabBar = false
  preferences.configuration = configuration
  #expect(try reasons() == ["layout", "layout", "disabled", "-"])

  configuration.appearance.showTabBar = true
  preferences.configuration = configuration
  #expect(try reasons() == ["-", "-", "disabled", "-"])
  await drainToolsMainQueue()
  #expect(recorder.pushes >= 2)
}
