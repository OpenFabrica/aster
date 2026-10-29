// `aster tab list` / `aster pane list` 与 MCP `list_tabs` / `list_panes` 共用的投影与文本渲染。
// 数据只来自 `session.snapshot`：客户端筛选，不新增控制方法，旧版 App 也能直接用。
import Foundation

/// 从会话快照投影出标签与 Pane 列表。
public enum SessionLayoutListing {
  /// 一个标签的一行。
  public struct TabRow: Codable, Equatable, Sendable {
    public var windowID: String
    public var tabID: String
    public var title: String?
    /// 标签是所在窗口的当前标签。
    public var selected: Bool
    /// 所在窗口是焦点窗口。
    public var windowFocused: Bool
    public var paneCount: Int

    private enum CodingKeys: String, CodingKey {
      case windowID = "window_id"
      case tabID = "tab_id"
      case title, selected
      case windowFocused = "window_focused"
      case paneCount = "pane_count"
    }

    /// 逐字段构造。
    public init(
      windowID: String, tabID: String, title: String? = nil, selected: Bool, windowFocused: Bool, paneCount: Int
    ) {
      self.windowID = windowID
      self.tabID = tabID
      self.title = title
      self.selected = selected
      self.windowFocused = windowFocused
      self.paneCount = paneCount
    }
  }

  /// `tab list --json` 的结果形状。
  public struct TabListResult: Codable, Equatable, Sendable {
    public var tabs: [TabRow]

    /// 构造结果。
    public init(tabs: [TabRow]) { self.tabs = tabs }
  }

  /// `pane list --json` 的结果形状；行直接复用协议里的 `PaneInfo`。
  public struct PaneListResult: Codable, Equatable, Sendable {
    public var panes: [PaneInfo]

    /// 构造结果。
    public init(panes: [PaneInfo]) { self.panes = panes }
  }

  // MARK: - 投影

  /// 列出标签。`window` 为 nil 列全部；否则接受窗口 ID，或窗口里任意标签 / Pane 的 ID、agent 名，
  /// 以及 `current`（焦点 Pane 所在窗口；CLI 会先把它换成调用者自己的 Pane ID）。找不到抛 `not_found`。
  public static func tabs(in snapshot: SessionSnapshot, window selector: String? = nil) throws -> [TabRow] {
    var windows = snapshot.windows
    if let selector {
      guard let window = windows.first(where: { matches($0, selector: selector, snapshot: snapshot) }) else {
        throw AsterControlError(code: .notFound, message: "找不到窗口：\(selector)")
      }
      windows = [window]
    }
    return windows.flatMap { window in
      window.tabs.map { tab in
        TabRow(
          windowID: window.windowID, tabID: tab.tabID, title: tab.title, selected: tab.focused,
          windowFocused: window.focused, paneCount: tab.panes.count)
      }
    }
  }

  /// 列出 Pane。`tab` 为 nil 列全部；否则接受标签 ID，或标签里任意 Pane 的 ID、agent 名，
  /// 以及 `current`（焦点 Pane 所在标签；CLI 会先把它换成调用者自己的 Pane ID）。找不到抛 `not_found`。
  public static func panes(in snapshot: SessionSnapshot, tab selector: String? = nil) throws -> [PaneInfo] {
    let tabs = snapshot.windows.flatMap(\.tabs)
    guard let selector else { return tabs.flatMap(\.panes) }
    let wanted = selector == "current" ? focusedPane(in: snapshot)?.paneID : selector
    guard let wanted, let tab = tabs.first(where: { $0.tabID == wanted || $0.panes.contains { matches($0, wanted) } })
    else {
      throw AsterControlError(code: .notFound, message: "找不到标签：\(selector)")
    }
    return tab.panes
  }

  /// 焦点窗口里当前标签的焦点 Pane；没有焦点窗口时为 nil。
  public static func focusedPane(in snapshot: SessionSnapshot) -> PaneInfo? {
    snapshot.windows.first(where: \.focused)?.tabs.first(where: \.focused)?.panes.first(where: \.focused)
  }

  /// 窗口选择器是否指向这个窗口。
  private static func matches(_ window: SessionSnapshot.Window, selector: String, snapshot: SessionSnapshot) -> Bool {
    let wanted = selector == "current" ? focusedPane(in: snapshot)?.windowID : selector
    guard let wanted else { return false }
    if window.windowID == wanted { return true }
    return window.tabs.contains { tab in tab.tabID == wanted || tab.panes.contains { matches($0, wanted) } }
  }

  /// Pane 选择器是否指向这个 Pane：短 ID，或 Pane 里 agent 的名字。
  private static func matches(_ pane: PaneInfo, _ selector: String) -> Bool {
    pane.paneID == selector || (pane.agent?.name).map { $0 == selector } == true
  }

  // MARK: - 文本渲染

  /// 标签表格：`*` 标出各窗口的当前标签，焦点窗口的 WINDOW 列再加 `*`。
  public static func renderTabs(_ rows: [TabRow]) -> String {
    guard !rows.isEmpty else { return "(no tabs)" }
    var table = [["TAB", "WINDOW", "PANES", "TITLE"]]
    for row in rows {
      table.append([
        row.tabID + (row.selected ? "*" : ""), row.windowID + (row.windowFocused ? "*" : ""),
        String(row.paneCount), row.title.flatMap { $0.isEmpty ? nil : $0 } ?? "-",
      ])
    }
    return render(table)
  }

  /// Pane 表格：PROCESS 列优先显示 agent（`codex:idle`），其次前台命令。
  public static func renderPanes(_ panes: [PaneInfo]) -> String {
    guard !panes.isEmpty else { return "(no panes)" }
    var table = [["PANE", "TAB", "KIND", "PROCESS", "CWD"]]
    for pane in panes {
      let process =
        pane.agent.map { "\($0.agent):\($0.agentStatus.rawValue)" }
        ?? pane.command.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
      table.append([
        pane.paneID + (pane.focused ? "*" : ""), pane.tabID, pane.kind.rawValue, process,
        pane.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? "-",
      ])
    }
    return render(table)
  }

  /// 左对齐等宽表格；最后一列不补空格。CLI 其它表格也用它，保持同一种排版。
  public static func render(_ rows: [[String]]) -> String {
    let columns = rows.map(\.count).max() ?? 0
    var widths = [Int](repeating: 0, count: columns)
    for row in rows {
      for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
    }
    return rows.map { row in
      row.enumerated().map { index, cell in
        index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
      }.joined(separator: "  ")
    }.joined(separator: "\n")
  }
}
