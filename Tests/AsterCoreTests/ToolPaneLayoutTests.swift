// 工具 Pane 的领域规则：容错解码、剔除工具 Pane（兄弟顶替）、快照不持久化工具 Pane、Recipe 拒绝工具 Pane、
// 最近终端查找。
import Foundation
import Testing

@testable import AsterCore

private let home = "/Users/tester"

/// 一个工具 Pane 描述。
private func toolPane(_ entryID: String = "aster.builtin/json") -> PaneDescriptor {
  PaneDescriptor(kind: .tool, workingDirectory: home, resourcePath: entryID)
}

/// 一个终端 Pane 描述。
private func terminalPane(_ directory: String = home) -> PaneDescriptor {
  PaneDescriptor(kind: .terminal, workingDirectory: directory)
}

// MARK: - 容错解码

@Test("不认识的 Pane 类型降级成同目录终端，整份快照仍能解码")
func unknownPaneKindDecodesAsTerminalWithoutFailingSnapshot() throws {
  let tabID = UUID()
  let unknownID = UUID()
  let editorID = UUID()
  let json = """
    {
      "selectedTabID": "\(tabID.uuidString)",
      "tabs": [{
        "id": "\(tabID.uuidString)",
        "title": "work",
        "layout": {"split": {
          "axis": "horizontal", "ratio": 0.5,
          "first": {"leaf": {"_0": {"id": "\(unknownID.uuidString)", "kind": "hologram",
            "workingDirectory": "/srv/app", "resourcePath": "plugin/feature"}}},
          "second": {"leaf": {"_0": {"id": "\(editorID.uuidString)", "kind": "editor",
            "workingDirectory": "/srv/app", "resourcePath": "/srv/app/README.md"}}}
        }}
      }]
    }
    """
  let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
  let panes = try #require(snapshot.tabs.first).layout.allPanes
  #expect(panes.count == 2)
  #expect(panes[0].id == unknownID)
  #expect(panes[0].kind == .terminal)
  #expect(panes[0].workingDirectory == "/srv/app")
  // 降级成终端后资源路径没有意义，不能带着别的类型的资源继续存在。
  #expect(panes[0].resourcePath == nil)
  #expect(panes[1].kind == .editor)
  #expect(panes[1].resourcePath == "/srv/app/README.md")
}

@Test("工具 Pane 按 tool 往返编码；缺少 kind 仍按结构损坏报错")
func toolPaneRoundTripsAndMissingKindStillFails() throws {
  let pane = toolPane()
  let decoded = try JSONDecoder().decode(PaneDescriptor.self, from: JSONEncoder().encode(pane))
  #expect(decoded == pane)

  let missingKind = #"{"id":"\#(UUID().uuidString)","workingDirectory":"/tmp"}"#
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(PaneDescriptor.self, from: Data(missingKind.utf8))
  }
}

// MARK: - 剔除 Pane

@Test("删除工具 Pane 后由兄弟子树顶替，其余方向与比例不变")
func removingToolPanesPromotesSiblings() throws {
  let left = terminalPane("/a")
  let tool = toolPane()
  let bottom = terminalPane("/b")
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(left),
    second: .split(axis: .vertical, first: .leaf(tool), second: .leaf(bottom), ratio: 0.3),
    ratio: 0.6)

  let kept = try #require(layout.removingToolPanes())
  #expect(kept == .split(axis: .horizontal, first: .leaf(left), second: .leaf(bottom), ratio: 0.6))
  // 没有工具 Pane 时原样返回。
  #expect(kept.removingToolPanes() == kept)
  // 整棵树都是工具 Pane 时返回 nil。
  let allTools = PaneLayout.split(axis: .vertical, first: .leaf(toolPane()), second: .leaf(toolPane()), ratio: 0.5)
  #expect(allTools.removingToolPanes() == nil)
  // 通用条件删除：按目录删。
  #expect(layout.removingPanes { $0.workingDirectory == "/a" }?.allPanes.map(\.id) == [tool.id, bottom.id])
}

@Test("保存快照时剔除工具 Pane，只剩工具 Pane 的标签不保存，选中项改到同工作区的相邻标签")
func workspaceSnapshotDropsToolPanesAndToolOnlyTabs() throws {
  let group = UUID()
  let otherGroup = UUID()
  let mixedTab = WorkspaceTabSnapshot(
    id: UUID(), title: "mixed",
    layout: .split(axis: .horizontal, first: .leaf(terminalPane()), second: .leaf(toolPane()), ratio: 0.5),
    workspaceGroupID: group)
  let toolOnlyTab = WorkspaceTabSnapshot(
    id: UUID(), title: "tool", layout: .leaf(toolPane()), workspaceGroupID: group)
  let otherGroupTab = WorkspaceTabSnapshot(
    id: UUID(), title: "other", layout: .leaf(terminalPane()), workspaceGroupID: otherGroup)
  let snapshot = WorkspaceSnapshot(
    selectedTabID: toolOnlyTab.id,
    tabs: [mixedTab, toolOnlyTab, otherGroupTab],
    dividerAfterTabIDs: [toolOnlyTab.id, mixedTab.id])

  let saved = snapshot.removingToolPanes()
  #expect(saved.tabs.map(\.id) == [mixedTab.id, otherGroupTab.id])
  #expect(saved.tabs.allSatisfy { $0.layout.allPanes.allSatisfy { $0.kind != .tool } })
  #expect(saved.tabs[0].layout == .leaf(mixedTab.layout.allPanes[0]))
  // 后面的标签属于别的工作区，选中项回到同工作区里前面的标签。
  #expect(saved.selectedTabID == mixedTab.id)
  #expect(saved.dividerAfterTabIDs == [mixedTab.id])
  // 编码结果里不出现 tool：旧版本读得回来。
  let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
  #expect(!encoded.contains("\"tool\""))
}

@Test("所有标签都只有工具 Pane 时快照没有标签，恢复时会新建默认标签")
func workspaceSnapshotWithOnlyToolTabsBecomesEmpty() {
  let tab = WorkspaceTabSnapshot(id: UUID(), title: "tool", layout: .leaf(toolPane()))
  let saved = WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab]).removingToolPanes()
  #expect(saved.tabs.isEmpty)
  #expect(saved.selectedTabID == tab.id)
}

// MARK: - 最近终端

@Test("工具 Pane 找同标签里最近的终端：先看兄弟子树，再逐层往上")
func nearestTerminalPrefersClosestSibling() {
  let farTerminal = terminalPane("/far")
  let tool = toolPane()
  let editor = PaneDescriptor(kind: .editor, workingDirectory: home, resourcePath: "/x.md")
  let nearTerminal = terminalPane("/near")
  // [far | [tool / [editor | near]]]
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(farTerminal),
    second: .split(
      axis: .vertical, first: .leaf(tool),
      second: .split(axis: .horizontal, first: .leaf(editor), second: .leaf(nearTerminal), ratio: 0.5),
      ratio: 0.5),
    ratio: 0.5)
  let isTerminal: (PaneDescriptor) -> Bool = { $0.kind == .terminal }
  #expect(layout.nearestPaneID(to: tool.id, where: isTerminal) == nearTerminal.id)
  #expect(layout.nearestPaneID(to: nearTerminal.id, where: isTerminal) == farTerminal.id)
  #expect(PaneLayout.leaf(tool).nearestPaneID(to: tool.id, where: isTerminal) == nil)
  #expect(layout.nearestPaneID(to: UUID(), where: isTerminal) == nil)
}

// MARK: - Recipe

/// 含给定 Pane 的单标签 Recipe。
private func recipe(with pane: WorkflowRecipePane, layout: PaneLayout? = nil) -> WorkflowRecipe {
  WorkflowRecipe(
    name: "tools", scope: .tab, content: .layoutOnly,
    tabs: [WorkflowRecipeTab(title: "tab", panes: [pane], layout: layout)])
}

@Test("Recipe 拒绝工具 Pane 并给出明确原因")
func workflowRecipeRejectsToolPanes() throws {
  let pane = WorkflowRecipePane(workingDirectory: "{{home_folder}}", kind: .tool, resourcePath: "aster.builtin/json")
  #expect(throws: WorkflowRecipeTOMLError.unsupportedPaneKind("tool")) {
    try WorkflowRecipeTOML.validate(recipe(with: pane))
  }
  // 精确布局里藏着工具 Pane 同样拒绝。
  let terminal = WorkflowRecipePane(workingDirectory: "{{home_folder}}")
  let layout = PaneLayout.leaf(PaneDescriptor(kind: .tool, workingDirectory: "{{home_folder}}", resourcePath: "a.b/c"))
  #expect(throws: WorkflowRecipeTOMLError.unsupportedPaneKind("tool")) {
    try WorkflowRecipeTOML.validate(recipe(with: terminal, layout: layout))
  }
  // 外部文件写了 kind = "tool"：导入失败，错误能直接显示给用户。
  let toml = """
    [recipe]
    name = "tools"
    version = 1
    scope = "tab"

    [[window.tabs]]
    title = "tab"

    [[window.tabs.panes]]
    cwd = "{{home_folder}}"
    kind = "tool"
    resource_path = "aster.builtin/json"
    """
  do {
    _ = try WorkflowRecipeTOML.decode(Data(toml.utf8), source: .recipeFile)
    Issue.record("含工具 Pane 的 Recipe 不应导入成功")
  } catch let error as WorkflowRecipeTOMLError {
    #expect(error == .unsupportedPaneKind("tool"))
    #expect(error.errorDescription?.isEmpty == false)
  }
  // 其它错误保持系统默认描述。
  #expect(WorkflowRecipeTOMLError.invalidStructure.errorDescription == nil)
}
