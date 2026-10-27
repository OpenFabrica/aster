// 工具面板的键盘路由：把按键翻译成面板命令。纯函数，不碰视图，便于测试各种焦点与工具状态的组合。
import AppKit

/// 面板能响应的键盘命令。
enum ToolLauncherCommand: Equatable {
  /// 结果列表上下移动选中行。
  case moveSelection(Int)
  /// 打开选中行（`↩`）。
  case open
  /// 把结果预填到来源终端（`⌘↩`）。
  case prefillResult
  /// 开成工作区 Pane（`⌥↩`）。
  case openAsPane
  /// 按可见顺序直接打开第 N 行（`⌘1`–`⌘9`）。
  case quickSelect(Int)
  /// 退出正在使用的工具，回到结果列表（工具打开时的 `Esc`）。
  case exitTool
  /// 关闭面板（没有工具时的 `Esc`）。
  case closePanel
}

/// 按键到命令的路由规则。
enum ToolLauncherKeyRouter {
  /// 路由需要知道的面板状态。
  struct Context: Equatable {
    /// 结果列表下方正展开着一个工具。
    var isToolOpen: Bool
    /// 键盘焦点在搜索框里（而不是工具自己的输入框）。
    var isSearchFieldFocused: Bool
    /// 输入法正在组字。
    var hasMarkedText: Bool
  }

  private static let returnKey: UInt16 = 36
  private static let keypadEnter: UInt16 = 76
  private static let escape: UInt16 = 53
  private static let downArrow: UInt16 = 125
  private static let upArrow: UInt16 = 126

  /// 返回 nil 表示按键不归面板，原样交给当前焦点（搜索框编辑、工具里的输入等）。
  ///
  /// - 输入法组字时一律放行：中文输入用 `↩`、`Esc`、方向键确认或取消候选，抢走会打断输入。
  /// - `↑`/`↓`/`↩` 只在焦点位于搜索框且没有打开工具时归面板；工具打开后这些键属于工具。
  /// - `⌘↩`、`⌥↩`、`Esc` 不看焦点：它们在工具里也表示「预填」「开成 Pane」「退出工具」。
  /// - `⌘1`–`⌘9` 只在结果列表可见（没有打开工具）时快选。
  static func command(
    keyCode: UInt16,
    characters: String?,
    modifiers: NSEvent.ModifierFlags,
    context: Context
  ) -> ToolLauncherCommand? {
    guard !context.hasMarkedText else { return nil }
    let flags = modifiers.intersection([.command, .option, .control, .shift])
    let listHasKeyboard = context.isSearchFieldFocused && !context.isToolOpen
    switch keyCode {
    case escape:
      guard flags.isEmpty else { return nil }
      return context.isToolOpen ? .exitTool : .closePanel
    case returnKey, keypadEnter:
      if flags == .command { return .prefillResult }
      if flags == .option { return .openAsPane }
      return flags.isEmpty && listHasKeyboard ? .open : nil
    case downArrow:
      return flags.isEmpty && listHasKeyboard ? .moveSelection(1) : nil
    case upArrow:
      return flags.isEmpty && listHasKeyboard ? .moveSelection(-1) : nil
    default:
      break
    }
    guard flags == .command, !context.isToolOpen,
      let digit = characters?.first?.wholeNumberValue, (1...9).contains(digit)
    else { return nil }
    return .quickSelect(digit)
  }
}
