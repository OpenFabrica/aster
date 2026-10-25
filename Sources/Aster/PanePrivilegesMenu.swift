// Notifications & Privileges 的菜单数据；呈现宿主负责非模态级联与菜单重建。
import AppKit
import AsterCore

@MainActor
enum PanePrivilegesMenu {
  /// 普通防休眠的确认由 Tab 宿主提供；其他操作只写共享运行期覆盖，不修改偏好。
  static func make(session: TerminalSession, preferences: AppPreferences,
    toggleCaffeinate: (() -> Void)? = nil
  ) -> NSMenu {
    let menu = NSMenu(title: L("通知与权限"))
    menu.autoenablesItems = false
    let state = session.privilegesState
    let values = state.privileges.resolved(in: preferences.configuration)
    func section(_ title: String) {
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    func toggle(_ title: String, _ field: PanePrivileges.Field) {
      let item = ActionMenuItem(title: title) { [weak state, weak preferences] in
        guard let state, let preferences else { return }
        state.toggle(field, inheriting: preferences.configuration)
      }
      item.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
      item.state = state.privileges.value(field, inheriting: preferences.configuration) ? .on : .off
      menu.addItem(item)
    }
    section(L("声音"))
    let soundMute = ActionMenuItem(title: L("静音")) { [weak state] in state?.muteSound() }
    soundMute.identifier = NSUserInterfaceItemIdentifier("muteSound")
    soundMute.state = values.soundOnErrorExit || values.terminalBell ? .off : .on
    menu.addItem(soundMute)
    toggle(L("错误退出时提示音"), .soundOnErrorExit)
    toggle(L("允许终端响铃"), .terminalBell)

    section(L("通知"))
    let notificationMute = ActionMenuItem(title: L("静音")) { [weak state] in state?.muteNotifications() }
    notificationMute.identifier = NSUserInterfaceItemIdentifier("muteNotifications")
    notificationMute.state = values.notifyOnFinish || values.notifyOnError
      || values.notifyOnWatchFinish || values.notificationShellControlled ? .off : .on
    menu.addItem(notificationMute)
    toggle(L("命令完成时通知"), .notifyOnFinish)
    toggle(L("错误退出时通知"), .notifyOnError)
    toggle(L("监视任务完成时通知"), .notifyOnWatchFinish)
    toggle(L("允许应用通知"), .notificationShellControlled)

    section(L("标签徽标"))
    if session.activeAgentProvider == nil {
      toggle(L("命令完成时"), .badgeCommandFinish)
      toggle(L("命令失败时"), .badgeCommandFailure)
    } else {
      toggle(L("处理期间"), .badgeAgentProcessing)
      toggle(L("任务完成时"), .badgeAgentTaskComplete)
      toggle(L("等待输入时"), .badgeAgentAwaitingInput)
    }
    section(L("防止休眠"))
    if session.activeAgentProvider == nil {
      let item = ActionMenuItem(title: L("任务运行时保持唤醒")) { toggleCaffeinate?() }
      item.identifier = NSUserInterfaceItemIdentifier("caffeinateTask")
      item.state = state.caffeinateMode == .off ? .off : .on
      item.isEnabled = toggleCaffeinate != nil
      menu.addItem(item)
    } else {
      toggle(L("处理期间防止休眠"), .caffeinateAgentProcessing)
    }
    section(L("鼠标"))
    toggle(L("允许鼠标捕获"), .allowMouseCapture)
    return menu
  }
}
