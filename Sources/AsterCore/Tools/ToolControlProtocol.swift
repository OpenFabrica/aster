// `tool.list` / `tool.run` 控制协议：让 `aster mcp` 等外部调用方列出并无界面地运行插件命令。
// 只描述数据与校验；能不能跑、怎么跑由 App 的 ToolCenter 决定，见 docs/developer/tools-and-plugins.md。
import Foundation

/// 插件命令的控制方法。与 `host.*` 一样单独成组，App 在通用分发之前拦截。
public enum ToolControlMethod: String, CaseIterable, Sendable {
  case toolList = "tool.list"
  case toolRun = "tool.run"
}

/// 插件命令在协议里的动作种类。
public enum ToolCommandKind: String, Codable, Equatable, Sendable {
  /// 插件自带的程序（`action.type == script`）。
  case script
  /// Aster 原生的内置转换。
  case builtin
  /// 网页界面，只能在 Aster 里打开。
  case ui
}

/// 插件在协议里的状态；`needs_approval` 时要先在 Aster 里确认一次权限。
public enum ToolCommandStatus: String, Codable, Equatable, Sendable {
  case ready
  case disabled
  case needsApproval = "needs_approval"
}

/// `tool.list` 里的一条命令（插件的一个功能）。
public struct ToolCommandInfo: Codable, Equatable, Sendable {
  /// `<pluginID>/<code>`，`tool.run` 用它指定命令。
  public var id: String
  public var pluginID: String
  public var pluginName: String
  public var title: String
  public var subtitle: String?
  public var keywords: [String]
  public var kind: ToolCommandKind
  /// 脚本的输出方式（`text` / `list` / `none` / `terminal`）；非脚本为 nil。
  public var output: String?
  public var status: ToolCommandStatus
  /// 能否经 `tool.run` 无界面运行。
  public var runnable: Bool
  /// 不能运行时的原因（给 agent 看的英文短句）。
  public var unavailableReason: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case pluginID = "plugin_id"
    case pluginName = "plugin_name"
    case title, subtitle, keywords, kind, output, status, runnable
    case unavailableReason = "unavailable_reason"
  }

  /// 逐字段构造。
  public init(
    id: String, pluginID: String, pluginName: String, title: String, subtitle: String? = nil,
    keywords: [String] = [], kind: ToolCommandKind, output: String? = nil, status: ToolCommandStatus,
    runnable: Bool, unavailableReason: String? = nil
  ) {
    self.id = id
    self.pluginID = pluginID
    self.pluginName = pluginName
    self.title = title
    self.subtitle = subtitle
    self.keywords = keywords
    self.kind = kind
    self.output = output
    self.status = status
    self.runnable = runnable
    self.unavailableReason = unavailableReason
  }
}

/// `tool.list` 参数：`query` 非空时按标题、关键词与插件名模糊筛选。
public struct ToolListParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var query: String?

  /// 构造参数。
  public init(query: String? = nil) { self.query = query }

  /// 查询只是筛选词，限制长度即可。
  public func validate() throws {
    if let query, query.utf8.count > ToolControlLimits.maximumQueryBytes {
      throw AsterControlError.invalidParams("query 过长（最多 \(ToolControlLimits.maximumQueryBytes) 字节）")
    }
  }
}

/// `tool.list` 结果。
public struct ToolListResult: Codable, Equatable, Sendable {
  public var tools: [ToolCommandInfo]

  /// 构造结果。
  public init(tools: [ToolCommandInfo]) { self.tools = tools }
}

/// `tool.run` 参数。
public struct ToolRunParams: Codable, Equatable, Sendable, AsterControlValidatable {
  /// `<pluginID>/<code>`。
  public var id: String
  /// 交给命令处理的文字（脚本从 stdin 读到它，内置转换直接处理它）；可省略。
  public var input: String?
  /// 脚本的工作目录（绝对路径）；不存在或省略时用用户主目录。
  public var cwd: String?

  /// 构造参数。
  public init(id: String, input: String? = nil, cwd: String? = nil) {
    self.id = id
    self.input = input
    self.cwd = cwd
  }

  /// 校验 id 形状、输入大小与目录格式；命令是否存在由 App 判断。
  public func validate() throws {
    guard !id.isEmpty, id.utf8.count <= ToolControlLimits.maximumIDBytes,
      ToolCatalogEntry.splitID(id) != nil,
      !id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else {
      throw AsterControlError.invalidParams("id 必须是 <插件 id>/<功能 code>")
    }
    if let input, input.utf8.count > ToolControlLimits.maximumInputBytes {
      throw AsterControlError.invalidParams("input 过长（最多 \(ToolControlLimits.maximumInputBytes) 字节）")
    }
    if let cwd {
      guard cwd.hasPrefix("/"), cwd.utf8.count <= ToolControlLimits.maximumPathBytes,
        !cwd.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
      else {
        throw AsterControlError.invalidParams("cwd 必须是绝对路径")
      }
    }
  }
}

/// `tool.run` 结果。`output` 决定看哪个字段：`text` 看 `text`，`list` 看 `items`，`none` 只表示已完成。
public struct ToolRunResult: Codable, Equatable, Sendable {
  public var id: String
  public var output: String
  public var text: String?
  public var items: [ToolListItem]?
  /// `text` 超过上限被截断。
  public var truncated: Bool
  public var durationMs: Int

  private enum CodingKeys: String, CodingKey {
    case id, output, text, items, truncated
    case durationMs = "duration_ms"
  }

  /// 逐字段构造。
  public init(
    id: String, output: String, text: String? = nil, items: [ToolListItem]? = nil, truncated: Bool = false,
    durationMs: Int
  ) {
    self.id = id
    self.output = output
    self.text = text
    self.items = items
    self.truncated = truncated
    self.durationMs = durationMs
  }
}

/// `tool.*` 的长度上限。
public enum ToolControlLimits {
  public static let maximumQueryBytes = 256
  public static let maximumIDBytes = 256
  /// 与 `pane send-text` 的文本上限同级：输入要整段进 stdin，不该比 socket 请求上限还大。
  public static let maximumInputBytes = 256 * 1_024
  public static let maximumPathBytes = 4_096
  /// 结果文本上限：控制协议单条响应最大 4 MiB，MCP 结果还要再进 agent 上下文，留足余量。
  public static let maximumOutputBytes = 512 * 1_024
}
