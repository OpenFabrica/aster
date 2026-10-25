// 管理 Pane 菜单的外部点击与应用失焦关闭，监听随弹层生命周期释放。
import AppKit
import Combine

@MainActor
final class PaneMenuDismissalMonitor {
  private let clickMonitor: AnyCancellable?
  private let deactivationMonitor: AnyCancellable

  init(window: NSWindow, menus: PaneMenuPresenter, toggleAnchor: NSView?, dismiss: @escaping () -> Void) {
    let token = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]) { [weak window, weak menus, weak toggleAnchor] event in
      guard let window, window.isVisible else { return event }
      if event.window === window || menus?.contains(window: event.window) == true { return event }
      // 入口按钮自身负责切换；提前关闭会让它的 action 把刚关闭的弹层重新打开。
      if let toggleAnchor, event.window === toggleAnchor.window,
        toggleAnchor.bounds.contains(toggleAnchor.convert(event.locationInWindow, from: nil)) { return event }
      dismiss()
      // 外部点击仍交给原目标，终端或其他控件可在同一次点击中正常取得焦点。
      return event
    }
    clickMonitor = token.map { token in AnyCancellable { NSEvent.removeMonitor(token) } }
    // 其他应用的鼠标事件不经过 local monitor；切换应用时统一收起整条级联菜单。
    deactivationMonitor = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
      .sink { _ in dismiss() }
  }
}
