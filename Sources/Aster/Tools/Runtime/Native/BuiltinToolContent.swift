// 内置原生工具界面的共同约定：工具会话按 handler 创建内容，输入变化时转交，结果供复制与预填。
import AppKit
import AsterCore

/// 原生工具界面用的终端主题与字体（JSON 树视图与终端配色一致）。
@MainActor
struct ToolTerminalStyle {
  let theme: TerminalTheme
  let font: NSFont

  /// 取 App 当前的终端主题与字体；不在 App 宿主里（测试）时按系统明暗退回 Ayu 主题与等宽系统字体。
  static func current() -> ToolTerminalStyle {
    if let preferences = (NSApp?.delegate as? AsterAppDelegate)?.preferences {
      return ToolTerminalStyle(theme: preferences.activeTheme, font: preferences.terminalFont)
    }
    let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let theme = TerminalThemeCatalog.resolve(
      named: isDark ? "Ayu Dark" : "Ayu Light", customThemes: [], mode: isDark ? .dark : .light)
    return ToolTerminalStyle(theme: theme, font: NSFont.interfaceMonospaced(ofSize: 12))
  }
}

/// 原生工具向工具会话请求的动作；由 `ToolSessionViewController` 提供，界面不直接碰容器。
@MainActor
struct BuiltinToolActions {
  /// 复制到剪贴板（会话负责写剪贴板并提示「已复制」）。
  let copy: @MainActor (String) -> Void
  /// 预填到来源终端（不回车）；失败时容器负责提示原因。
  let insertIntoTerminal: @MainActor (String) -> Void
  /// 在容器里显示一条短提示。
  let showNotice: @MainActor (_ text: String, _ isError: Bool) -> Void
  /// 内容希望的高度变了（会话转给容器）。
  let heightDidChange: @MainActor () -> Void
  /// 主结果变了（会话据此刷新底部按钮的可用状态）。
  let resultDidChange: @MainActor () -> Void
  /// 弹确认框、文件选择框时挂靠的窗口；没有窗口时用模态。
  let window: @MainActor () -> NSWindow?
  /// JSON 树视图使用的终端主题与字体。
  let terminalStyle: @MainActor () -> ToolTerminalStyle
}

/// 一个内置原生工具的界面。只在主线程使用；耗时计算（文件 Hash、端口扫描、大 JSON 解析）
/// 必须放到后台，并按发起时的输入代次回写，`teardown()` 之后不再回调 `actions`。
@MainActor
protocol BuiltinToolContent: AnyObject {
  /// 放进工具会话的根视图。
  var view: NSView { get }
  /// 希望的内容高度（点）。
  var preferredHeight: CGFloat { get }
  /// 当前可复制或预填的结果；没有就 nil。
  var primaryResultText: String? { get }
  /// 输入变化（启动器继续输入、同一工具再次打开）。
  func update(input: ToolInput)
  /// 取消后台任务与定时器；之后不再回调 `actions`。
  func teardown()
}
