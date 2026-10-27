// 启动器看到的工具条目、工具输入与匹配结果。只描述数据，不负责扫描或运行。
import Foundation

/// 插件来源。来源决定能否用 builtin 动作、是否需要确认、是否比对文件摘要。
public enum ToolPluginSource: String, Codable, Sendable {
  /// 随 App 签名发布。
  case builtin
  /// 安装在插件目录里。
  case user
  /// 登记的开发目录，文件随时会变。
  case development
}

/// 启动器里的一行：某个可用插件的一个功能。
public struct ToolCatalogEntry: Identifiable, Equatable, Sendable {
  /// `<pluginID>/<code>`，也是使用记录与工具 Pane `resourcePath` 的键。
  public var id: String { Self.makeID(pluginID: pluginID, code: feature.code) }
  public let pluginID: String
  public let pluginName: String
  public let pluginVersion: String
  public let source: ToolPluginSource
  public let feature: ToolFeature
  /// 已解析成绝对路径的图标；没有则用默认图标。
  public let iconPath: String?
  /// 插件是否有网页界面（`ui` 字段）。
  public let hasUI: Bool

  public init(
    pluginID: String,
    pluginName: String,
    pluginVersion: String,
    source: ToolPluginSource,
    feature: ToolFeature,
    iconPath: String? = nil,
    hasUI: Bool = false
  ) {
    self.pluginID = pluginID
    self.pluginName = pluginName
    self.pluginVersion = pluginVersion
    self.source = source
    self.feature = feature
    self.iconPath = iconPath
    self.hasUI = hasUI
  }

  /// 组合功能 id。
  public static func makeID(pluginID: String, code: String) -> String {
    "\(pluginID)/\(code)"
  }

  /// 拆分功能 id；格式不对返回 nil。
  public static func splitID(_ id: String) -> (pluginID: String, code: String)? {
    guard let slash = id.lastIndex(of: "/") else { return nil }
    let pluginID = String(id[..<slash])
    let code = String(id[id.index(after: slash)...])
    guard !pluginID.isEmpty, !code.isEmpty else { return nil }
    return (pluginID, code)
  }
}

/// 输入从哪里来。
public enum ToolInputSource: String, Codable, Sendable {
  case none
  /// 启动器里敲的或粘贴的文字。
  case typed
  case clipboard
  /// 终端选区。
  case selection
  /// 拖进来或选中的文件。
  case file
}

/// 打开工具时的环境，随输入一起交给插件。
public struct ToolContext: Codable, Equatable, Sendable {
  /// 来源 Pane 的本地工作目录；远端 Pane 为 nil。
  public var workingDirectory: String?
  public var isRemote: Bool
  /// 界面语言代码，如 `zh-Hans`、`en`。
  public var locale: String
  /// `light` 或 `dark`。
  public var appearance: String

  public init(workingDirectory: String? = nil, isRemote: Bool = false, locale: String = "zh-Hans", appearance: String = "dark") {
    self.workingDirectory = workingDirectory
    self.isRemote = isRemote
    self.locale = locale
    self.appearance = appearance
  }
}

/// 交给工具处理的内容。
public struct ToolInput: Codable, Equatable, Sendable {
  public var text: String?
  /// 绝对路径。
  public var files: [String]
  public var source: ToolInputSource
  public var context: ToolContext

  public init(text: String? = nil, files: [String] = [], source: ToolInputSource = .none, context: ToolContext = ToolContext()) {
    self.text = text
    self.files = files
    self.source = source
    self.context = context
  }

  /// 没有任何内容。
  public var isEmpty: Bool { (text ?? "").isEmpty && files.isEmpty }
}

/// 一次匹配的结果。
public struct ToolMatch: Equatable, Sendable {
  public enum Reason: Equatable, Sendable {
    /// 标题、关键词或插件名命中查询。
    case search
    /// 输入内容命中第 `ruleIndex` 条 match 规则。
    case content(ruleIndex: Int, label: String?)
  }

  public let entry: ToolCatalogEntry
  public let reason: Reason
  /// 越大越靠前。
  public let score: Double

  public init(entry: ToolCatalogEntry, reason: Reason, score: Double) {
    self.entry = entry
    self.reason = reason
    self.score = score
  }
}

extension ToolMatch {
  /// 是否由 text 规则命中。text 规则接受任意文字（最多排除几种），命中只说明「能处理文字」，
  /// 不说明内容就是这个工具要的东西；启动器据此把这类「识别到」排在关键词搜索结果后面。
  public var isTextRuleMatch: Bool {
    guard case .content(let ruleIndex, _) = reason, entry.feature.match.indices.contains(ruleIndex),
      case .text = entry.feature.match[ruleIndex]
    else { return false }
    return true
  }
}
