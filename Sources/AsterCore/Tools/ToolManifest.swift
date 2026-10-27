// 工具插件清单 `aster-plugin.json` 的模型。字段与校验规则见 docs/developer/tools-and-plugins.md；
// 严格解码在 ToolManifestDecoding.swift，取值校验在 ToolManifestValidation.swift。
import Foundation

/// 插件清单 v1。只有经过 `decode(_:source:)` 校验的值才能进入工具中心。
public struct ToolManifest: Codable, Equatable, Sendable {
  public static let fileName = "aster-plugin.json"
  public static let currentSchemaVersion = 1
  /// 内置插件保留的 id 前缀。
  public static let builtinIDPrefix = "aster."

  public var schemaVersion: Int
  public var id: String
  public var name: String
  public var version: String
  public var description: String?
  public var author: String?
  public var homepage: String?
  /// 相对插件目录的图标路径。
  public var icon: String?
  /// 有它才能使用 `ui` 动作（网页工具）。
  public var ui: ToolUIConfig?
  public var permissions: [ToolPermission]
  /// 允许访问的域名；只在声明 `network` 权限时非空。
  public var network: [String]
  public var features: [ToolFeature]

  public init(
    schemaVersion: Int = ToolManifest.currentSchemaVersion,
    id: String,
    name: String,
    version: String,
    description: String? = nil,
    author: String? = nil,
    homepage: String? = nil,
    icon: String? = nil,
    ui: ToolUIConfig? = nil,
    permissions: [ToolPermission] = [],
    network: [String] = [],
    features: [ToolFeature]
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.name = name
    self.version = version
    self.description = description
    self.author = author
    self.homepage = homepage
    self.icon = icon
    self.ui = ui
    self.permissions = permissions
    self.network = network
    self.features = features
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, id, name, version, description, author, homepage, icon, ui, permissions, network,
      features
  }

  /// 数组字段缺省视为空，其余缺省字段保持 nil；未知字段的拒绝在 `decode(_:source:)` 里统一做。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    version = try values.decode(String.self, forKey: .version)
    description = try values.decodeIfPresent(String.self, forKey: .description)
    author = try values.decodeIfPresent(String.self, forKey: .author)
    homepage = try values.decodeIfPresent(String.self, forKey: .homepage)
    icon = try values.decodeIfPresent(String.self, forKey: .icon)
    ui = try values.decodeIfPresent(ToolUIConfig.self, forKey: .ui)
    permissions = try values.decodeIfPresent([ToolPermission].self, forKey: .permissions) ?? []
    network = try values.decodeIfPresent([String].self, forKey: .network) ?? []
    features = try values.decode([ToolFeature].self, forKey: .features)
  }

  /// 网页工具的入口与默认高度。
  public var resolvedUIHeight: Int { ui?.height ?? ToolUIConfig.defaultHeight }

  /// 按 id 查功能。
  public func feature(code: String) -> ToolFeature? {
    features.first { $0.code == code }
  }
}

/// 网页工具界面配置。
public struct ToolUIConfig: Codable, Equatable, Sendable {
  public static let defaultHeight = 480
  public static let heightRange = 120...800
  /// 相对插件目录的 `.html` 入口。
  public var main: String
  public var height: Int?

  public init(main: String, height: Int? = nil) {
    self.main = main
    self.height = height
  }
}

/// 插件里的一个功能，对应启动器里的一行。
public struct ToolFeature: Codable, Equatable, Sendable {
  public var code: String
  public var title: String
  public var subtitle: String?
  public var icon: String?
  public var keywords: [String]
  public var match: [ToolMatchRule]
  public var action: ToolAction

  public init(
    code: String,
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    keywords: [String] = [],
    match: [ToolMatchRule] = [],
    action: ToolAction
  ) {
    self.code = code
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.keywords = keywords
    self.match = match
    self.action = action
  }

  private enum CodingKeys: String, CodingKey {
    case code, title, subtitle, icon, keywords, match, action
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    code = try values.decode(String.self, forKey: .code)
    title = try values.decode(String.self, forKey: .title)
    subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
    icon = try values.decodeIfPresent(String.self, forKey: .icon)
    keywords = try values.decodeIfPresent([String].self, forKey: .keywords) ?? []
    match = try values.decodeIfPresent([ToolMatchRule].self, forKey: .match) ?? []
    action = try values.decode(ToolAction.self, forKey: .action)
  }
}

// MARK: - 匹配规则

/// 内容匹配规则：输入文本或文件命中时，启动器在「识别到」里主动推荐该功能。
public enum ToolMatchRule: Equatable, Sendable {
  case regex(ToolRegexRule)
  case text(ToolTextRule)
  case files(ToolFilesRule)

  /// 「识别到」行显示的标签。
  public var label: String? {
    switch self {
    case .regex(let rule): rule.label
    case .text(let rule): rule.label
    case .files(let rule): rule.label
    }
  }
}

/// 正则匹配文本。
public struct ToolRegexRule: Codable, Equatable, Sendable {
  public static let defaultMaxLength = 10_000
  public var label: String?
  public var pattern: String
  public var minLength: Int?
  public var maxLength: Int?

  public init(label: String? = nil, pattern: String, minLength: Int? = nil, maxLength: Int? = nil) {
    self.label = label
    self.pattern = pattern
    self.minLength = minLength
    self.maxLength = maxLength
  }
}

/// 匹配任意文本（可排除一部分）。
public struct ToolTextRule: Codable, Equatable, Sendable {
  public var label: String?
  public var exclude: String?
  public var minLength: Int?
  public var maxLength: Int?

  public init(label: String? = nil, exclude: String? = nil, minLength: Int? = nil, maxLength: Int? = nil) {
    self.label = label
    self.exclude = exclude
    self.minLength = minLength
    self.maxLength = maxLength
  }
}

/// 文件或目录类型。
public enum ToolFileType: String, Codable, Sendable {
  case file
  case directory
}

/// 匹配文件或文件夹。
public struct ToolFilesRule: Codable, Equatable, Sendable {
  public var label: String?
  public var fileType: ToolFileType?
  public var extensions: [String]?
  public var pattern: String?
  public var minCount: Int?
  public var maxCount: Int?

  public init(
    label: String? = nil,
    fileType: ToolFileType? = nil,
    extensions: [String]? = nil,
    pattern: String? = nil,
    minCount: Int? = nil,
    maxCount: Int? = nil
  ) {
    self.label = label
    self.fileType = fileType
    self.extensions = extensions
    self.pattern = pattern
    self.minCount = minCount
    self.maxCount = maxCount
  }
}

extension ToolMatchRule: Codable {
  private enum Kind: String, Codable {
    case regex, text, files
  }

  private enum TypeKey: String, CodingKey {
    case type
  }

  /// 以 `type` 字段区分规则种类，其余字段由具体规则解码。
  public init(from decoder: any Decoder) throws {
    let kind = try decoder.container(keyedBy: TypeKey.self).decode(Kind.self, forKey: .type)
    switch kind {
    case .regex: self = .regex(try ToolRegexRule(from: decoder))
    case .text: self = .text(try ToolTextRule(from: decoder))
    case .files: self = .files(try ToolFilesRule(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: TypeKey.self)
    switch self {
    case .regex(let rule):
      try container.encode(Kind.regex, forKey: .type)
      try rule.encode(to: encoder)
    case .text(let rule):
      try container.encode(Kind.text, forKey: .type)
      try rule.encode(to: encoder)
    case .files(let rule):
      try container.encode(Kind.files, forKey: .type)
      try rule.encode(to: encoder)
    }
  }
}

// MARK: - 动作

/// 选中功能后做什么。
public enum ToolAction: Equatable, Sendable {
  /// 打开插件的网页界面。
  case ui
  /// 运行插件自带的程序。
  case script(ToolScriptAction)
  /// 由 Aster 原生实现；只允许内置来源。
  case builtin(ToolBuiltinAction)
}

/// 脚本输出的处理方式。
public enum ToolScriptOutput: String, Codable, Sendable {
  case text
  case list
  case none
  case terminal
}

/// 脚本 stdin 的内容格式。
public enum ToolStdinMode: String, Codable, Sendable {
  case text
  case json
}

/// 脚本动作。`command[0]` 是可执行文件，其余是参数；输入永远只走 stdin。
public struct ToolScriptAction: Codable, Equatable, Sendable {
  public var command: [String]
  public var output: ToolScriptOutput
  public var stdin: ToolStdinMode
  /// 秒；缺省按输出模式取默认值。
  public var timeout: Double?

  public init(command: [String], output: ToolScriptOutput = .text, stdin: ToolStdinMode = .text, timeout: Double? = nil) {
    self.command = command
    self.output = output
    self.stdin = stdin
    self.timeout = timeout
  }

  private enum CodingKeys: String, CodingKey {
    case command, output, stdin, timeout
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    command = try values.decode([String].self, forKey: .command)
    output = try values.decodeIfPresent(ToolScriptOutput.self, forKey: .output) ?? .text
    stdin = try values.decodeIfPresent(ToolStdinMode.self, forKey: .stdin) ?? .text
    timeout = try values.decodeIfPresent(Double.self, forKey: .timeout)
  }

  /// 实际生效的超时秒数。
  public var resolvedTimeout: TimeInterval {
    if let timeout { return min(max(timeout, 1), ScriptToolProtocol.maximumTimeout) }
    return output == .list ? ScriptToolProtocol.listTimeout : ScriptToolProtocol.defaultTimeout
  }
}

/// 内置原生动作。
public struct ToolBuiltinAction: Codable, Equatable, Sendable {
  public var handler: ToolBuiltinHandler

  public init(handler: ToolBuiltinHandler) {
    self.handler = handler
  }
}

extension ToolAction: Codable {
  private enum Kind: String, Codable {
    case ui, script, builtin
  }

  private enum TypeKey: String, CodingKey {
    case type
  }

  public init(from decoder: any Decoder) throws {
    let kind = try decoder.container(keyedBy: TypeKey.self).decode(Kind.self, forKey: .type)
    switch kind {
    case .ui: self = .ui
    case .script: self = .script(try ToolScriptAction(from: decoder))
    case .builtin: self = .builtin(try ToolBuiltinAction(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: TypeKey.self)
    switch self {
    case .ui:
      try container.encode(Kind.ui, forKey: .type)
    case .script(let action):
      try container.encode(Kind.script, forKey: .type)
      try action.encode(to: encoder)
    case .builtin(let action):
      try container.encode(Kind.builtin, forKey: .type)
      try action.encode(to: encoder)
    }
  }
}
