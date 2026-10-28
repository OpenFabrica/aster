// bar 项目 onClick 的门禁与执行。脚本输出只是数据：六种动作逐项按插件的可用权限放行，
// 越权或不合规时整条拒绝并用窗口提示说明原因。门禁表见 docs/developer/tools-and-plugins.md「界面扩展」。
import AppKit
import AsterCore

/// 终端写入目标；生产是 `ToolTerminalOrigin`（粘贴保护、只读与 Vi 门禁照常生效）。
@MainActor
protocol ToolBarTerminalTarget: AnyObject {
  /// 预填，永不回车。失败返回给用户看的原因。
  func insert(_ text: String) -> String?
  /// 写入并回车。失败返回给用户看的原因。
  func submit(_ text: String) -> String?
}

extension ToolTerminalOrigin: ToolBarTerminalTarget {}

/// 一次点击的结果（测试据此断言；用户看到的是提示）。
enum ToolBarActionOutcome: Equatable {
  case performed
  /// 用户在确认框里取消了。
  case declined
  /// 被门禁拒绝或执行失败，附提示文案。
  case rejected(String)
}

/// bar 动作执行器。每窗口一份，只在主线程使用。
@MainActor
final class ToolBarActionPerformer {
  /// `submit` 提示里命令预览的字符数。
  static let submitPreviewLength = 80

  private let services: ToolBridgeServices
  private let terminal: () -> ToolBarTerminalTarget?
  private let viewEntries: () -> [ToolViewEntry]
  private let featureEntry: (_ entryID: String) -> ToolCatalogEntry?
  private let launchFeature: (_ entry: ToolCatalogEntry, _ text: String?) -> Void
  private let revealPanel: (_ entryID: String) -> Void
  private let refresh: (_ entryID: String) -> Void
  private let notify: (_ message: String) -> Void
  private let window: () -> NSWindow?
  /// 网址确认框还开着；再点只提示，不叠第二个框。
  private var isConfirming = false

  /// 各项能力都可注入；生产由 WorkspaceExtensionHost 接到窗口模型、工具中心与系统服务。
  init(
    services: ToolBridgeServices,
    terminal: @escaping () -> ToolBarTerminalTarget?,
    viewEntries: @escaping () -> [ToolViewEntry],
    featureEntry: @escaping (_ entryID: String) -> ToolCatalogEntry?,
    launchFeature: @escaping (_ entry: ToolCatalogEntry, _ text: String?) -> Void,
    revealPanel: @escaping (_ entryID: String) -> Void,
    refresh: @escaping (_ entryID: String) -> Void,
    notify: @escaping (_ message: String) -> Void,
    window: @escaping () -> NSWindow?
  ) {
    self.services = services
    self.terminal = terminal
    self.viewEntries = viewEntries
    self.featureEntry = featureEntry
    self.launchFeature = launchFeature
    self.revealPanel = revealPanel
    self.refresh = refresh
    self.notify = notify
    self.window = window
  }

  /// 执行 `entry` 视图里某个项目的动作。被拒绝或失败时同时发窗口提示。
  /// `pane.bottom` 的条传自己 Pane 的 feed 键与终端：`refresh` 重跑这一份，`terminal` 写到条所在的 Pane，
  /// 而不是当前活动 Pane。
  @discardableResult
  func perform(
    _ action: ToolBarAction,
    from entry: ToolViewEntry,
    feedKey: String? = nil,
    terminal paneTerminal: ToolBarTerminalTarget? = nil
  ) async -> ToolBarActionOutcome {
    let outcome = await execute(action, from: entry, feedKey: feedKey ?? entry.id, terminal: paneTerminal)
    if case .rejected(let message) = outcome { notify(message) }
    return outcome
  }

  /// 门禁与执行本体。
  private func execute(
    _ action: ToolBarAction,
    from entry: ToolViewEntry,
    feedKey: String,
    terminal paneTerminal: ToolBarTerminalTarget?
  ) async -> ToolBarActionOutcome {
    switch action {
    case .copy(let text, let concealed):
      guard entry.permissions.contains(.clipboardWrite) else {
        return .rejected(L("插件「\(entry.pluginName)」没有写剪贴板的权限"))
      }
      services.writeClipboardText(text, concealed: concealed)
      return .performed
    case .terminal(let text, let mode):
      return writeToTerminal(text, mode: mode, from: entry, target: paneTerminal ?? terminal())
    case .openURL(let url):
      return await open(url, from: entry)
    case .openPanel(let viewID):
      guard let panel = viewEntries().first(where: { Self.isOpenablePanel($0, viewID: viewID, from: entry) }) else {
        return .rejected(L("插件「\(entry.pluginName)」没有可以打开的面板「\(viewID)」"))
      }
      revealPanel(panel.id)
      return .performed
    case .refresh:
      refresh(feedKey)
      return .performed
    case .feature(let code, let text):
      // 功能 id 由本插件 id 拼出：脚本只能打开自己插件里、目录中仍可用的功能。
      guard let feature = featureEntry("\(entry.pluginID)/\(code)"), feature.pluginID == entry.pluginID else {
        return .rejected(L("插件「\(entry.pluginName)」里没有可用的功能「\(code)」"))
      }
      launchFeature(feature, text)
      return .performed
    }
  }

  /// `terminal` 动作：要 `terminal.insert` 权限。`submit` 额外拒绝含 Unicode Cc 控制字符（含换行、制表符、ESC）
  /// 的整条文本，与 `ToolShellCommand.encode` 的检查一致：换行会提前执行半条命令，制表符触发补全，
  /// ESC 序列触发行编辑器按键绑定，这些都在用户看到之前生效。`insert` 不回车，多行预填交给粘贴保护。
  private func writeToTerminal(
    _ text: String,
    mode: ToolBarTerminalMode,
    from entry: ToolViewEntry,
    target: ToolBarTerminalTarget?
  ) -> ToolBarActionOutcome {
    guard entry.permissions.contains(.terminalInsert) else {
      return .rejected(L("插件「\(entry.pluginName)」没有写入终端的权限"))
    }
    if mode == .submit, Self.containsControlCharacters(text) {
      return .rejected(ToolShellCommand.EncodingError.controlCharacters.localizedDescription)
    }
    guard let terminal = target else { return .rejected(L("当前没有可以写入的终端")) }
    let failure = mode == .submit ? terminal.submit(text) : terminal.insert(text)
    return failure.map(ToolBarActionOutcome.rejected) ?? .performed
  }

  /// `openURL`：只认 http(s)，每次都弹确认（与网页桥接 `shell.openURL` 同一个确认框）。
  private func open(_ url: URL, from entry: ToolViewEntry) async -> ToolBarActionOutcome {
    guard let allowed = WebPaneURLPolicy.allowedURL(from: url.absoluteString) else {
      return .rejected(L("只允许 http(s) 地址"))
    }
    guard !isConfirming else { return .rejected(L("已经有一个对话框在等待处理")) }
    isConfirming = true
    defer { isConfirming = false }
    guard await services.confirmOpening(allowed, pluginName: entry.pluginName, window: window()) else {
      return .declined
    }
    services.openInBrowser(allowed)
    return .performed
  }

  /// `openPanel` 的目标：同插件、panel 类型、当前可挂载。
  private static func isOpenablePanel(_ candidate: ToolViewEntry, viewID: String, from entry: ToolViewEntry) -> Bool {
    candidate.pluginID == entry.pluginID && candidate.contribution.id == viewID
      && candidate.contribution.kind == .panel && candidate.isMountable
  }

  /// 是否含 Unicode Cc（C0、DEL、C1）。
  static func containsControlCharacters(_ text: String) -> Bool {
    text.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }

  /// 项目的 tooltip：`submit` 在末尾追加要执行的命令预览，用户点之前就能看到会跑什么。
  static func tooltip(for item: ToolBarItem) -> String? {
    guard case .terminal(let text, .submit)? = item.action else { return item.tooltip }
    let preview =
      text.count > submitPreviewLength ? String(text.prefix(submitPreviewLength)) + "…" : text
    let line = L("↩ 执行：\(preview)")
    guard let tooltip = item.tooltip, !tooltip.isEmpty else { return line }
    return "\(tooltip)\n\(line)"
  }
}
