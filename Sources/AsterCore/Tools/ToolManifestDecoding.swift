// 清单的严格解码：逐层拒绝未知字段，再做类型解码，并把 DecodingError 换成带字段路径的 ToolManifestError。
import Foundation

/// 清单不合格的原因。`field` 是出错字段的路径，例如 `features[1].match[0].pattern`。
public struct ToolManifestError: Error, Equatable, Sendable, LocalizedError {
  public let field: String
  public let reason: String

  /// 指定出错字段的路径与给用户看的原因。
  public init(field: String, reason: String) {
    self.field = field
    self.reason = reason
  }

  public var errorDescription: String? { "\(field): \(reason)" }
}

extension ToolManifest {
  /// 清单文件大小上限。
  public static let maximumFileBytes = 64 * 1_024

  /// 解析并完整校验清单；任何一条规则不满足都抛出 `ToolManifestError`。
  public static func decode(_ data: Data, source: ToolPluginSource) throws -> ToolManifest {
    guard data.count <= maximumFileBytes else {
      throw ToolManifestError(field: fileName, reason: L("清单文件太大"))
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw ToolManifestError(field: fileName, reason: L("清单必须是 UTF-8 文本"))
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ToolManifestError(field: fileName, reason: L("不是有效的清单 JSON"))
    }
    guard let root = object as? [String: Any] else {
      throw ToolManifestError(field: fileName, reason: L("清单必须是 JSON 对象"))
    }
    try ToolManifestKeyChecker.check(root)
    let manifest: ToolManifest
    do {
      manifest = try JSONDecoder().decode(ToolManifest.self, from: data)
    } catch let error as DecodingError {
      throw ToolManifestError(decodingError: error)
    } catch {
      throw ToolManifestError(field: fileName, reason: L("不是有效的清单 JSON"))
    }
    try manifest.validate(source: source)
    return manifest
  }
}

// MARK: - 未知字段

/// 按层级核对字段名与整数字段。类型解码会忽略多余的键，所以拼错的字段必须在这里硬失败；
/// 整数字段写成小数时 JSONDecoder 报的错不带字段路径，也在这里先查出来。
enum ToolManifestKeyChecker {
  static let rootKeys: Set<String> = [
    "schemaVersion", "id", "name", "version", "description", "author", "homepage", "icon", "ui", "permissions",
    "network", "features", "contributes",
  ]
  static let uiKeys: Set<String> = ["main", "height"]
  static let contributesKeys: Set<String> = ["views"]
  static let viewKeys: Set<String> = ["id", "title", "kind", "slot", "icon", "height", "source", "refresh", "main"]
  static let viewSourceKeys: Set<String> = ["type", "command", "timeout"]
  static let refreshKeys: Set<String> = ["interval", "on"]
  static let featureKeys: Set<String> = ["code", "title", "subtitle", "icon", "keywords", "match", "action"]
  /// match 规则的字段随 `type` 不同；`type` 缺失或不认识时交给类型解码报错。
  static let matchKeys: [String: Set<String>] = [
    "regex": ["type", "label", "pattern", "minLength", "maxLength"],
    "text": ["type", "label", "exclude", "minLength", "maxLength"],
    "files": ["type", "label", "fileType", "extensions", "pattern", "minCount", "maxCount"],
  ]
  static let actionKeys: [String: Set<String>] = [
    "ui": ["type"],
    "script": ["type", "command", "output", "stdin", "timeout"],
    "builtin": ["type", "handler"],
  ]

  /// 检查整份清单；结构类型不对的层级跳过，由随后的类型解码给出精确错误。
  static func check(_ root: [String: Any]) throws {
    try reject(root, allowed: rootKeys, path: "")
    try requireInteger(root["schemaVersion"], path: "schemaVersion")
    if let ui = root["ui"] as? [String: Any] {
      try reject(ui, allowed: uiKeys, path: "ui")
      try requireInteger(ui["height"], path: "ui.height")
    }
    try checkContributes(root["contributes"])
    guard let features = root["features"] as? [Any] else { return }
    for (index, element) in features.enumerated() {
      guard let feature = element as? [String: Any] else { continue }
      let path = "features[\(index)]"
      try reject(feature, allowed: featureKeys, path: path)
      if let rules = feature["match"] as? [Any] {
        for (ruleIndex, ruleElement) in rules.enumerated() {
          guard let rule = ruleElement as? [String: Any], let type = rule["type"] as? String,
            let allowed = matchKeys[type]
          else { continue }
          let rulePath = "\(path).match[\(ruleIndex)]"
          try reject(rule, allowed: allowed, path: rulePath)
          for key in integerRuleKeys {
            try requireInteger(rule[key], path: "\(rulePath).\(key)")
          }
        }
      }
      if let action = feature["action"] as? [String: Any], let type = action["type"] as? String,
        let allowed = actionKeys[type]
      {
        try reject(action, allowed: allowed, path: "\(path).action")
      }
    }
  }

  /// 检查 `contributes` 节：每一层拒绝未知字段，`height`、`timeout`、`interval` 必须是整数。
  private static func checkContributes(_ value: Any?) throws {
    guard let contributes = value as? [String: Any] else { return }
    try reject(contributes, allowed: contributesKeys, path: "contributes")
    guard let views = contributes["views"] as? [Any] else { return }
    for (index, element) in views.enumerated() {
      guard let view = element as? [String: Any] else { continue }
      let path = "contributes.views[\(index)]"
      try reject(view, allowed: viewKeys, path: path)
      try requireInteger(view["height"], path: "\(path).height")
      if let source = view["source"] as? [String: Any] {
        try reject(source, allowed: viewSourceKeys, path: "\(path).source")
        try requireInteger(source["timeout"], path: "\(path).source.timeout")
      }
      if let refresh = view["refresh"] as? [String: Any] {
        try reject(refresh, allowed: refreshKeys, path: "\(path).refresh")
        try requireInteger(refresh["interval"], path: "\(path).refresh.interval")
      }
    }
  }

  /// match 规则里的整数字段。
  static let integerRuleKeys = ["minLength", "maxLength", "minCount", "maxCount"]

  /// 数字必须是能放进 Int 的整数；不是数字（含布尔）时跳过，交给类型解码报类型错误。
  static func requireInteger(_ value: Any?, path: String) throws {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return }
    let double = number.doubleValue
    guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else {
      throw ToolManifestError(field: path, reason: L("必须是整数"))
    }
  }

  /// 有不认识的键就抛错；多个时按字母序报第一个，保证错误稳定。
  static func reject(_ object: [String: Any], allowed: Set<String>, path: String) throws {
    guard let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first else { return }
    throw ToolManifestError(field: path.isEmpty ? unknown : "\(path).\(unknown)", reason: L("不支持的字段"))
  }
}

// MARK: - 类型错误

extension ToolManifestError {
  /// 把 JSONDecoder 的错误换成字段路径 + 原因。
  init(decodingError: DecodingError) {
    switch decodingError {
    case .keyNotFound(let key, let context):
      self.init(field: Self.fieldPath(context.codingPath + [key]), reason: L("缺少必填字段"))
    case .typeMismatch(_, let context):
      self.init(field: Self.fieldPath(context.codingPath), reason: L("类型不对"))
    case .valueNotFound(_, let context):
      self.init(field: Self.fieldPath(context.codingPath), reason: L("不能为 null"))
    case .dataCorrupted(let context):
      // 语法在前一步已经检查过；路径为空通常是某个数字放不进目标类型，JSONDecoder 没给出位置。
      if context.codingPath.isEmpty {
        self.init(field: ToolManifest.fileName, reason: L("清单里有无法解析的取值"))
      } else {
        self.init(field: Self.fieldPath(context.codingPath), reason: L("取值无效"))
      }
    @unknown default:
      self.init(field: ToolManifest.fileName, reason: L("不是有效的清单 JSON"))
    }
  }

  /// `[features, 1, match, 0, pattern]` → `features[1].match[0].pattern`。数组下标的 key 带 intValue。
  static func fieldPath(_ codingPath: [any CodingKey]) -> String {
    var path = ""
    for key in codingPath {
      if let index = key.intValue {
        path += "[\(index)]"
      } else {
        path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
      }
    }
    return path.isEmpty ? ToolManifest.fileName : path
  }
}
