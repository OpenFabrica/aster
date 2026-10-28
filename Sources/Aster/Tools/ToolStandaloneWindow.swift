// 工具与便笺的独立窗口基类。它不是工作区窗口：AppDelegate 据此把 ⌘W 等关闭类菜单动作落到这个窗口本身，
// 不能误关背后工作区的活动 Pane；分屏类菜单在它拿着键盘时置灰。
import AppKit

/// 独立工具窗口与便笺窗口共用的窗口类型。
@MainActor
class ToolStandaloneWindow: NSWindow {
  /// `⌘↩` 的处理；返回 true 表示已处理。没设置时按普通按键继续分派。
  var onCommandReturn: (() -> Bool)?
  /// 是否跟随 App 的明暗设置。便笺固定浅色纸面，设为 false。
  var followsAppAppearance = true

  /// 拦下 `⌘↩`（预填到终端）；其余按键等价物照常交给菜单与视图。
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if flags == .command, event.keyCode == 36 || event.keyCode == 76, let onCommandReturn, onCommandReturn() {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
