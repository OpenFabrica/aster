// agent 主机终端找调用方 Pane 的接口：Pane 还在不在、切过去看、Pane 关闭时通知。
// 生产实现包控制桥（`AsterControlBridge`），测试用替身。控制服务没起来时没有定位器，
// 终端一律用独立浮窗，行为与停靠功能之前相同。
import AppKit
import AsterCore

/// 停靠呈现需要的 Pane 查询。
@MainActor
protocol AgentHostPaneLocator: AnyObject {
  /// Pane 是否还挂在某个工作区标签里。
  func isPaneAlive(_ paneID: UUID) -> Bool
  /// 切到 Pane 所在的标签（必要时先取消放大别的 Pane），并把它的窗口提到前面。
  func revealPane(_ paneID: UUID)
  /// 有 Pane 关闭后回调（下一轮主队列）。不保证是停靠的那个，收到后逐个用 `isPaneAlive` 核对。
  var onPanesClosed: (() -> Void)? { get set }
}

/// 生产实现：经控制桥按 UUID 查 Pane，订阅 `pane.closed`。
@MainActor
final class ControlBridgeAgentHostPaneLocator: AgentHostPaneLocator {
  private weak var bridge: AsterControlBridge?
  private let subscriberID = UUID()
  var onPanesClosed: (() -> Void)?

  /// 订阅 `pane.closed`。事件在桥更新 Pane 集合的过程中发出，延后一轮再处理，免得在桥的回调里搬视图。
  init(bridge: AsterControlBridge) {
    self.bridge = bridge
    bridge.hub.subscribe(id: subscriberID, kinds: [.paneClosed]) { [weak self] _ in
      DispatchQueue.main.async { self?.onPanesClosed?() }
    }
  }

  func isPaneAlive(_ paneID: UUID) -> Bool { bridge?.record(paneUUID: paneID) != nil }

  /// 与用量看板的「跳到会话」同一条路径；标签正放大着别的 Pane 时先还原，否则停靠区所在的 Pane 不在视图树里。
  func revealPane(_ paneID: UUID) {
    guard let record = bridge?.record(paneUUID: paneID) else { return }
    if let zoomed = record.tab.zoomedPaneID, zoomed != paneID { record.tab.toggleZoom() }
    record.model.revealWorkspaceLocation(tabID: record.tab.id, paneID: paneID)
    record.model.onRequestWindowFocus?()
  }
}
