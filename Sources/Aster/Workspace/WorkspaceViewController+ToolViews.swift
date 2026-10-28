// 工作区窗口与插件界面扩展的挂载胶水：把扩展宿主接到窗口、整树刷新与 Inspector。
// bar 的插入点在 WorkspaceView.swift 的 makeTerminalWorkspace（tab.top 在查找条之后，tab.bottom 在 composer 之后）。
import AppKit
import AsterCore

extension WorkspaceViewController {
  /// viewDidLoad 时接线：窗口用于可见性与确认框；bar 位置的有无变化合并成一次整树刷新（内容变化只重画条本身）；
  /// `openPanel` 动作打开 Inspector 并选中插件面板。
  func installToolViewHost() {
    extensionHost.windowProvider = { [weak self] in self?.viewIfLoaded?.window }
    extensionHost.onMountedSlotsChanged = { [weak self] in self?.scheduleRefresh() }
    extensionHost.onRevealPanel = { [weak self] entryID in self?.revealPluginPanel(entryID: entryID) }
  }

  /// 打开 Inspector（经模型的局部展示事件，不触发整树重建）并选中插件面板页签。
  func revealPluginPanel(entryID: String) {
    model.isInspectorPresented = true
    detailsControllerForSelectedTab().selectPluginPanel(entryID: entryID)
  }
}
