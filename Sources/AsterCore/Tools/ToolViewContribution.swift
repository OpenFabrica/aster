// 插件清单 `contributes.views[]`：插件挂到工作区窗口上的界面（原生状态条 bar 与网页面板 panel）。
// 只描述数据；取值校验在 ToolViewContributionValidation.swift，规则见 docs/developer/tools-and-plugins.md「界面扩展」。
import Foundation

/// 视图类型：原生横条（脚本给项目列表，Aster 绘制）或网页面板（WKWebView 沙箱）。
public enum ToolViewKind: String, Codable, CaseIterable, Sendable {
  case bar
  case panel
}

/// 视图取上下文的范围。
public enum ToolViewContextScope: String, Sendable {
  /// 窗口级：取窗口当前选中标签。
  case window
  /// 当前选中标签：cwd 取其活动 Pane。
  case tab
  /// 单个 Pane。
  case pane
}

/// 挂载点。原始值就是清单里的 `slot` 字符串。
public enum ToolViewSlot: String, Codable, CaseIterable, Sendable {
  case windowTop = "window.top"
  case windowBottom = "window.bottom"
  case sidebarSection = "sidebar.section"
  case tabTop = "tab.top"
  case tabBottom = "tab.bottom"
  case paneHeader = "pane.header"
  case paneBottom = "pane.bottom"
  /// 只挂在当前聚焦的终端 Pane 底部，焦点换到哪个 Pane 条就移到哪个 Pane；上下文同 `tab.*`（活动 Pane）。
  case activePaneBottom = "activePane.bottom"
  case inspectorPanel = "inspector.panel"

  /// 这个挂载点接受的视图类型。
  public var kinds: Set<ToolViewKind> {
    switch self {
    case .inspectorPanel: [.panel]
    case .sidebarSection: [.bar, .panel]
    case .windowTop, .windowBottom, .tabTop, .tabBottom, .paneHeader, .paneBottom, .activePaneBottom: [.bar]
    }
  }

  /// 上下文范围。
  public var scope: ToolViewContextScope {
    switch self {
    case .windowTop, .windowBottom, .sidebarSection: .window
    case .tabTop, .tabBottom, .activePaneBottom, .inspectorPanel: .tab
    case .paneHeader, .paneBottom: .pane
    }
  }

  /// bar 的高度范围（点）；不接受 bar 的挂载点为 nil。`sidebar.section` 的 bar 是纵向列表，高度由行数决定。
  public var barHeightRange: ClosedRange<Int>? {
    switch self {
    case .tabTop, .tabBottom, .windowBottom: 22...28
    case .windowTop: 28...28
    case .paneBottom, .activePaneBottom: 20...26
    case .paneHeader: 14...14
    case .sidebarSection: 24...24
    case .inspectorPanel: nil
    }
  }

  /// bar 缺省高度（点）。
  public var defaultBarHeight: Int? {
    switch self {
    case .tabTop, .tabBottom, .windowBottom: 26
    case .windowTop: 28
    case .paneBottom, .activePaneBottom, .sidebarSection: 24
    case .paneHeader: 14
    case .inspectorPanel: nil
    }
  }

  /// 本版本已经能挂载的挂载点。其余挂载点清单可以声明（向前兼容），但视图不挂载、不跑脚本，
  /// 设置页显示「本版本暂不支持这个位置」。
  public var isImplemented: Bool {
    switch self {
    case .windowTop, .windowBottom, .sidebarSection, .tabTop, .tabBottom, .paneBottom, .activePaneBottom, .inspectorPanel:
      true
    case .paneHeader: false
    }
  }

  /// 同一视图可以改放的挂载点：接受该类型、且本版本已实现。
  public static func slots(accepting kind: ToolViewKind) -> [ToolViewSlot] {
    allCases.filter { $0.kinds.contains(kind) && $0.isImplemented }
  }
}

/// bar 重跑脚本的上下文触发源。
public enum ToolViewRefreshTrigger: String, Codable, CaseIterable, Sendable {
  /// 活动 Pane 的工作目录变化（含本地 / 远端切换）。
  case cwd
  /// 当前仓库分支变化（监听 `.git`）。
  case branch
  /// 活动 Pane 变化。
  case activePane
  /// 活动 Pane 的 Agent 状态变化。
  case agent
}

/// bar 的刷新策略。
public struct ToolViewRefresh: Codable, Equatable, Sendable {
  public static let defaultInterval = 60
  /// 0 表示只按触发与手动刷新；否则 5–3600 秒。
  public static let intervalRange = 5...3600
  public static let defaultTriggers: [ToolViewRefreshTrigger] = [.cwd]
  public static let maximumTriggers = 4

  public var interval: Int?
  public var on: [ToolViewRefreshTrigger]?

  public init(interval: Int? = nil, on: [ToolViewRefreshTrigger]? = nil) {
    self.interval = interval
    self.on = on
  }

  /// 生效的定时间隔（秒）；0 表示不定时。
  public var resolvedInterval: Int { interval ?? Self.defaultInterval }
  /// 生效的触发源。
  public var resolvedTriggers: [ToolViewRefreshTrigger] { on ?? Self.defaultTriggers }
}

/// bar 的数据源：插件自带的脚本，stdout 按 `ToolBarProtocol` 输出项目列表。
public struct ToolViewScriptSource: Codable, Equatable, Sendable {
  public static let defaultTimeout = 5
  public static let timeoutRange = 1...30

  /// 目前只有 `script`。
  public var type: String
  /// 规则同功能脚本的 `command`：裸名按固定 PATH 查找，含 `/` 的相对路径相对插件目录，绝对路径原样使用。
  public var command: [String]
  /// 秒。
  public var timeout: Int?

  public init(type: String = "script", command: [String], timeout: Int? = nil) {
    self.type = type
    self.command = command
    self.timeout = timeout
  }

  /// 生效的超时（秒）。
  public var resolvedTimeout: TimeInterval { TimeInterval(timeout ?? Self.defaultTimeout) }
}

/// 清单里声明的一个视图。
public struct ToolViewContribution: Codable, Equatable, Identifiable, Sendable {
  public static let maximumViews = 16
  /// `sidebar.section` 面板的高度范围与缺省值。
  public static let sidebarPanelHeightRange = 80...400
  public static let defaultSidebarPanelHeight = 240

  /// 插件内唯一，规则同功能 `code`。
  public var id: String
  public var title: String
  public var kind: ToolViewKind
  /// 清单给的缺省挂载点；用户可以在设置页改到同类型的其它位置。
  public var slot: ToolViewSlot
  /// 相对插件目录的图标。
  public var icon: String?
  /// bar：条高；`sidebar.section` 面板：面板高；其它挂载点忽略。
  public var height: Int?
  /// bar 必填。
  public var source: ToolViewScriptSource?
  /// 只用于 bar。
  public var refresh: ToolViewRefresh?
  /// panel 必填：相对插件目录的 `.html` 入口。
  public var main: String?

  public init(
    id: String,
    title: String,
    kind: ToolViewKind,
    slot: ToolViewSlot,
    icon: String? = nil,
    height: Int? = nil,
    source: ToolViewScriptSource? = nil,
    refresh: ToolViewRefresh? = nil,
    main: String? = nil
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.slot = slot
    self.icon = icon
    self.height = height
    self.source = source
    self.refresh = refresh
    self.main = main
  }

  /// 在给定挂载点上生效的 bar 高度。
  public func barHeight(in slot: ToolViewSlot) -> Int? {
    guard let range = slot.barHeightRange, let fallback = slot.defaultBarHeight else { return nil }
    guard let height, range.contains(height) else { return fallback }
    return height
  }

  /// 生效的刷新策略（bar 缺省按 cwd 触发、60 秒定时）。
  public var resolvedRefresh: ToolViewRefresh { refresh ?? ToolViewRefresh() }
}

/// 清单的 `contributes` 节。可选，旧插件没有它。
public struct ToolContributions: Codable, Equatable, Sendable {
  public var views: [ToolViewContribution]

  public init(views: [ToolViewContribution] = []) {
    self.views = views
  }

  /// 缺 `views` 视为空数组。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    views = try values.decodeIfPresent([ToolViewContribution].self, forKey: .views) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case views
  }
}
