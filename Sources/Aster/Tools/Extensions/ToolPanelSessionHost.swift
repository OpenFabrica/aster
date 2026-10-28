// 插件 panel 视图作为工具会话的容器（第四种 ToolSessionHost）：常驻在窗口上（Inspector 页签或侧栏区块），
// 不能被工具自己关掉；Inspector 的高度由宿主决定，侧栏接受 `ui.setHeight`（夹到 80–400）；提示走工作区 toast；
// 预填与运行命令都按窗口当前的活动终端。
import AppKit
import AsterCore

/// panel 视图的会话容器。会话对宿主是弱引用，宿主由 `ToolPanelSessionCache` 持有。
@MainActor
final class ToolPanelSessionHost: ToolSessionHost {
  private weak var model: AppModel?
  /// 承载的会话；只用来找它所在的窗口。
  weak var session: ToolSessionViewController?
  /// 视图所在的位置；决定接不接受 `ui.setHeight`。
  let slot: ToolViewSlot
  /// 侧栏面板请求了新高度（已夹到 `ToolViewContribution.sidebarPanelHeightRange`）；由会话缓存接到窗口宿主。
  var onHeightRequest: ((CGFloat) -> Void)?

  /// 绑定所属窗口的模型与视图位置。
  init(model: AppModel?, slot: ToolViewSlot = .inspectorPanel) {
    self.model = model
    self.slot = slot
  }

  /// panel 由用户在设置里关掉，不响应 `ui.close`；提示原因，避免页面以为已经关了。
  func toolSessionDidRequestClose(_ session: ToolSessionViewController) {
    model?.notice = L("界面扩展视图不能自己关闭，可以在设置的「工具」里关掉它")
  }

  /// Inspector 填满内容区，忽略 `ui.setHeight`；侧栏区块夹到 80–400 后交给窗口改高度约束。
  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat) {
    guard slot == .sidebarSection else { return }
    onHeightRequest?(Self.clampedSidebarHeight(height))
  }

  /// 侧栏面板高度夹到清单允许的范围。
  static func clampedSidebarHeight(_ height: CGFloat) -> CGFloat {
    let range = ToolViewContribution.sidebarPanelHeightRange
    return min(max(height.rounded(), CGFloat(range.lowerBound)), CGFloat(range.upperBound))
  }

  /// 工作区只有一种提示（toast），错误与普通提示共用。
  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool) {
    model?.notice = text
  }

  /// 写到窗口当前的活动终端；panel 跟随标签切换，不认打开时的来源。
  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool {
    guard let model else { return false }
    guard let target = model.toolTerminalOrigin() else {
      model.notice = L("没有可以预填的终端")
      return false
    }
    if let failure = target.insert(text) {
      model.notice = failure
      return false
    }
    return true
  }

  /// 把 panel 当前的输入开成工具 Pane。合成的 `view:<id>` 功能不在目录里，找不到时由 `openToolPane` 提示。
  func toolSessionOpenInPane(_ session: ToolSessionViewController) {
    guard let model else { return }
    model.openToolPane(
      entryID: session.request.entry.id, input: session.request.input, origin: model.toolTerminalOrigin())
  }

  /// 在新标签里运行命令。
  func toolSession(
    _ session: ToolSessionViewController,
    runInTerminal command: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) {
    model?.runToolCommandInNewTab(command, workingDirectory: workingDirectory, environment: environment)
  }

  /// 会话视图所在的窗口；页签没选中、视图不在视图树里时为 nil。
  var toolSessionWindow: NSWindow? { session?.viewIfLoaded?.window }
}
