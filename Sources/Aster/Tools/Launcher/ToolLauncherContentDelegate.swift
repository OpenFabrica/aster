// 工具面板内容区（ToolLauncherViewController）与窗口控制器（ToolLauncherController）之间的意图约定：
// 内容区只负责展示与输入，打开、预填、开成 Pane、收起等动作由窗口控制器执行。
import AppKit
import AsterCore

/// 内容区向窗口控制器转交的用户意图。
@MainActor
protocol ToolLauncherContentDelegate: AnyObject {
  /// 打开一行（`↩`、点击、`⌘1`–`⌘9`）。`queryText` 是工具打开后留在搜索框里的文字。
  func launcherContent(
    _ content: ToolLauncherViewController, open row: ToolLauncherRow, input: ToolInput, queryText: String)
  /// `⌘↩`：把结果预填到来源终端。
  func launcherContentDidRequestPrefill(_ content: ToolLauncherViewController)
  /// `⌥↩`：开成工作区 Pane。
  func launcherContentDidRequestOpenAsPane(_ content: ToolLauncherViewController)
  /// 工具打开后搜索框继续输入。
  func launcherContent(_ content: ToolLauncherViewController, toolQueryChanged text: String)
  /// 工具打开时拖入了文件。
  func launcherContent(_ content: ToolLauncherViewController, toolReceivedFiles files: [String])
  /// 工具打开时的 `Esc`。
  func launcherContentDidRequestExitTool(_ content: ToolLauncherViewController)
  /// 没有工具时的 `Esc`。
  func launcherContentDidRequestClose(_ content: ToolLauncherViewController)
  /// 点了图钉：切换钉住。
  func launcherContentDidTogglePin(_ content: ToolLauncherViewController)
  /// 内容高度变了（结果行数、工具展开或收起、工具请求新高度）。
  func launcherContentDidChangeHeight(_ content: ToolLauncherViewController, animated: Bool)
}
