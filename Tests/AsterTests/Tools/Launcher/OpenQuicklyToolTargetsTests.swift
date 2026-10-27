// Open Quickly 工具行的接线：过滤器决定是否出行，「识别到」带行内结果时主动作是复制。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Test("Open Quickly：识别到时间戳时置顶，主动作复制结果；「全部」空查询与其它过滤器不出工具行")
func openQuicklyToolTargetsBuildRowsPerFilter() throws {
  // 工具中心组装环境时读 NSApp 的外观。
  _ = NSApplication.shared
  let suite = "OpenQuicklyToolTargets.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let timestampID = ToolCatalogEntry.makeID(
    pluginID: BuiltinToolCatalog.pluginID, code: ToolBuiltinHandler.timestamp.rawValue)
  try #require(ToolCenter.shared.entry(id: timestampID) != nil)
  let targets = OpenQuicklyToolTargets(model: model) {}

  let rows = targets.entries(query: "1700000000", filter: .all)
  let recognized = try #require(rows.first { $0.item.id == "tool-match:\(timestampID)" })
  #expect(recognized.item.kind == .tool)
  #expect(recognized.accented)
  #expect(recognized.badge == L("识别到"))
  #expect(recognized.actionTitle == L("复制结果"))
  #expect(!recognized.item.detail.isEmpty)
  #expect(recognized.menuActions.map(\.title) == [L("预填到终端"), L("在工具面板打开"), L("开成 Pane")])
  // 认出时间戳的行排第一，默认选中它。
  #expect(rows.first?.item.id == "tool-match:\(timestampID)")

  #expect(targets.entries(query: "", filter: .all).isEmpty)
  #expect(targets.entries(query: "json", filter: .file).isEmpty)
  let toolPage = targets.entries(query: "", filter: .tool)
  #expect(!toolPage.isEmpty)
  #expect(toolPage.allSatisfy { $0.item.id.hasPrefix("tool:") && $0.actionTitle == L("在工具面板打开") })
  #expect(toolPage.allSatisfy { $0.menuActions.map(\.title) == [L("开成 Pane")] })
}

@MainActor
@Test("Open Quickly：输入工具名「json」时默认选中搜索行，什么文字都收的「计算 Hash」排在 JSON 后面")
func openQuicklyToolNameQueryKeepsTextRuleMatchesBelowSearch() throws {
  _ = NSApplication.shared
  let suite = "OpenQuicklyToolTargets.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let jsonID = ToolCatalogEntry.makeID(pluginID: BuiltinToolCatalog.pluginID, code: ToolBuiltinHandler.json.rawValue)
  let hashID = ToolCatalogEntry.makeID(pluginID: BuiltinToolCatalog.pluginID, code: ToolBuiltinHandler.hash.rawValue)
  let targets = OpenQuicklyToolTargets(model: model) {}

  let ids = targets.entries(query: "json", filter: .tool).map(\.item.id)
  #expect(ids.first?.hasPrefix("tool:") == true)
  let json = try #require(ids.firstIndex(of: "tool:\(jsonID)"))
  let hash = try #require(ids.firstIndex(of: "tool-match:\(hashID)"))
  #expect(json < hash)
}
