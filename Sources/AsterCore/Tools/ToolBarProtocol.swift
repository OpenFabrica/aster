// bar 视图的脚本协议：stdin / 环境变量的组装与 stdout 项目列表的解析校验。纯函数，不依赖 AppKit；
// 脚本的运行、调度与绘制在应用层（Sources/Aster/Tools/Extensions/）。规则见 docs/developer/tools-and-plugins.md「界面扩展」。
import Foundation

/// 这一次运行脚本的原因，写进 stdin 的 `trigger` 与 `ASTER_TRIGGER`。
public enum ToolBarTrigger: String, Codable, CaseIterable, Sendable {
  /// 视图第一次挂载。
  case initial
  /// 定时到点。
  case interval
  case cwd
  case branch
  case activePane
  case agent
  /// 用户点了刷新、失败后点击重跑、插件文件或授权变化。
  case manual
}

/// 活动 Pane 的 Agent 摘要。
public struct ToolBarAgentContext: Codable, Equatable, Hashable, Sendable {
  public var provider: String
  public var state: String
  /// Pane 绑定的 Agent 会话 ID（hook 上报或按会话文件定位）；还没绑定时为 nil。
  /// 脚本据此读取「这个 Pane 自己的」会话记录，同目录多个 Agent 不会互相串。
  public var sessionID: String?

  public init(provider: String, state: String, sessionID: String? = nil) {
    self.provider = provider
    self.state = state
    self.sessionID = sessionID
  }

  private enum CodingKeys: String, CodingKey {
    case provider, state, sessionID
  }

  /// 按 stdin 约定写出：没绑定会话时 `sessionID` 写 `null` 而不是省略。
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(provider, forKey: .provider)
    try values.encode(state, forKey: .state)
    try values.encode(sessionID, forKey: .sessionID)
  }
}

/// bar 脚本看到的上下文。也是调度器判断「上下文变没变」的键（`Hashable`）。
public struct ToolBarContext: Codable, Equatable, Hashable, Sendable {
  /// 活动 Pane 的本地工作目录；远端为 nil。
  public var workingDirectory: String?
  public var isRemote: Bool
  public var locale: String
  /// `light` 或 `dark`。
  public var appearance: String
  public var branch: String?
  public var tabID: String?
  public var paneID: String?
  public var agent: ToolBarAgentContext?

  public init(
    workingDirectory: String? = nil,
    isRemote: Bool = false,
    locale: String = "zh-Hans",
    appearance: String = "dark",
    branch: String? = nil,
    tabID: String? = nil,
    paneID: String? = nil,
    agent: ToolBarAgentContext? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.isRemote = isRemote
    self.locale = locale
    self.appearance = appearance
    self.branch = branch
    self.tabID = tabID
    self.paneID = paneID
    self.agent = agent
  }
}

/// 颜色令牌，由宿主映射到主题色。
public enum ToolBarColorToken: String, Codable, CaseIterable, Sendable {
  case accent, success, warning, error, secondary
}

/// 项目颜色：`#RRGGBB` / `#RRGGBBAA`（分量 0–1）或主题令牌。
public enum ToolBarColor: Equatable, Sendable {
  case rgba(red: Double, green: Double, blue: Double, alpha: Double)
  case token(ToolBarColorToken)
}

/// `terminal` 动作的写入方式。
public enum ToolBarTerminalMode: String, Codable, Sendable {
  /// 预填，不回车。
  case insert
  /// 写入并回车执行。
  case submit
}

/// 点击项目时的动作。只有这几种；权限门禁在应用层 `ToolBarActionPerformer`。
public enum ToolBarAction: Equatable, Sendable {
  case copy(text: String, concealed: Bool)
  case terminal(text: String, mode: ToolBarTerminalMode)
  /// 只允许 http / https；每次都要用户确认。
  case openURL(URL)
  /// 打开同插件的 panel 视图（视图 id）。
  case openPanel(viewID: String)
  /// 立即重跑本视图脚本。
  case refresh
  /// 在工具面板打开同插件的功能，可带输入文本。
  case feature(code: String, text: String?)
}

/// 条上的一项。
public struct ToolBarItem: Equatable, Sendable {
  /// 可选，用于跨刷新保持悬停状态。
  public var id: String?
  public var text: String?
  /// SF Symbol 名；系统里没有这个符号时宿主丢掉图标、保留文字。
  public var symbol: String?
  /// 插件目录内图标文件的绝对路径（解析阶段已确认在目录内）。
  public var iconFile: String?
  public var color: ToolBarColor?
  public var tooltip: String?
  public var action: ToolBarAction?

  public init(
    id: String? = nil,
    text: String? = nil,
    symbol: String? = nil,
    iconFile: String? = nil,
    color: ToolBarColor? = nil,
    tooltip: String? = nil,
    action: ToolBarAction? = nil
  ) {
    self.id = id
    self.text = text
    self.symbol = symbol
    self.iconFile = iconFile
    self.color = color
    self.tooltip = tooltip
    self.action = action
  }
}

/// 一次脚本输出。
public struct ToolBarOutput: Equatable, Sendable {
  public var items: [ToolBarItem]
  /// 覆盖下一次定时间隔（秒）。
  public var ttl: Int?

  public init(items: [ToolBarItem] = [], ttl: Int? = nil) {
    self.items = items
    self.ttl = ttl
  }

  /// 没有项目：宿主隐藏这一段。
  public var isEmpty: Bool { items.isEmpty }
}

/// 解析失败。
public enum ToolBarError: Error, Equatable, Sendable, LocalizedError {
  case outputTooLarge
  case invalidOutput(String)

  public var errorDescription: String? {
    switch self {
    case .outputTooLarge: L("输出超过 64 KiB")
    case .invalidOutput(let reason): L("输出格式不对：\(reason)")
    }
  }
}

/// 协议常量与纯函数。
public enum ToolBarProtocol {
  public static let stdoutLimit = 65_536
  /// 横条最多项目数。
  public static let itemLimit = 12
  /// `sidebar.section` 纵向列表最多项目数。
  public static let listItemLimit = 32
  public static let textLimit = 64
  public static let tooltipLimit = 256
  public static let symbolLimit = 64
  /// `copy` / `terminal` 动作文本上限（字节）。
  public static let actionTextLimit = 65_536
  public static let ttlRange = 5...3600
  /// 触发去抖（秒），与 list 脚本相同。
  public static let debounce: TimeInterval = ScriptToolProtocol.listDebounce
  /// 同一视图两次运行的最短间隔（秒）。
  public static let minimumInterval: TimeInterval = 5
  /// 连续失败这么多次后退避。
  public static let failureBackoffThreshold = 3
  /// 退避后的最短间隔（秒）。
  public static let failureBackoffMinimum: TimeInterval = 300

  /// 解析 stdout。超过 `stdoutLimit` 抛 `.outputTooLarge`；外层结构不对抛 `.invalidOutput`；
  /// 单项不合格（未知动作类型、字段超限、图标越界等）只丢该项。空 stdout 视为没有项目。
  /// `pluginDirectory` 用来把 `iconFile` 解析成目录内的绝对路径；为 nil 时丢弃 `iconFile`。
  public static func parse(_ data: Data, pluginDirectory: URL?, itemLimit: Int = itemLimit) throws -> ToolBarOutput {
    // 实现见 ToolBarProtocolParsing.swift。
    try ToolBarOutputParser.parse(data, pluginDirectory: pluginDirectory, itemLimit: itemLimit)
  }

  /// stdin：`{"view", "trigger", "context": {…}}`，可选值写 `null`，键按字母序。
  public static func stdinData(viewID: String, trigger: ToolBarTrigger, context: ToolBarContext) -> Data {
    ToolBarOutputParser.stdinData(viewID: viewID, trigger: trigger, context: context)
  }

  /// 在功能脚本的 `ASTER_*` 变量之上追加 `ASTER_VIEW`、`ASTER_TRIGGER`、`ASTER_BRANCH`，
  /// 有 Agent 时再加 `ASTER_AGENT`（provider）与 `ASTER_AGENT_SESSION`（已绑定的会话 ID）。
  public static func environment(
    viewID: String,
    trigger: ToolBarTrigger,
    context: ToolBarContext
  ) -> [String: String] {
    ToolBarOutputParser.environment(viewID: viewID, trigger: trigger, context: context)
  }
}
