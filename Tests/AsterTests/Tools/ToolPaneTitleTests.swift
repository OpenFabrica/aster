// 工具 Pane 的显示名：功能 id 不能被当成文件名，出现在控制接口、标签标题规则与新标签标题里。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Test("工具 Pane 显示功能标题；功能不存在时显示「工具」；非工具 Pane 没有工具显示名")
func toolPaneDisplayTitleUsesFeatureTitle() throws {
  // 工具中心组装环境时读 NSApp 的外观。
  _ = NSApplication.shared
  let entryID = ToolCatalogEntry.makeID(pluginID: BuiltinToolCatalog.pluginID, code: ToolBuiltinHandler.json.rawValue)
  let entry = try #require(ToolCenter.shared.entry(id: entryID))
  let tool = PaneDescriptor(kind: .tool, workingDirectory: "/tmp", resourcePath: entryID)
  #expect(tool.toolDisplayTitle == entry.feature.title)

  let missing = PaneDescriptor(kind: .tool, workingDirectory: "/tmp", resourcePath: "com.example.gone/run")
  #expect(missing.toolDisplayTitle == L("工具"))

  let editor = PaneDescriptor(kind: .editor, workingDirectory: "/tmp", resourcePath: "/tmp/notes.md")
  #expect(editor.toolDisplayTitle == nil)
}

@MainActor
@Test("标签标题规则不把工具 Pane 的功能 id 当成 ${file}")
func tabTitleContextOmitsToolPaneFile() {
  let tool = PaneDescriptor(kind: .tool, workingDirectory: "/tmp", resourcePath: "aster.builtin/json")
  let tab = TerminalTabItem(title: "Tool", workingDirectory: "/tmp", layout: .leaf(tool))
  #expect(TabTitleRuleService.context(for: tab, index: 1).file == nil)
}
