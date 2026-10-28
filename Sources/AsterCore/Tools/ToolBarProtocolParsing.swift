// bar 脚本协议的解析与编码实现（ToolBarProtocol 的内部细节）：stdout 项目列表的逐项校验、stdin 与环境变量的组装。
import Foundation

/// `ToolBarProtocol` 的实现细节。
enum ToolBarOutputParser {
  /// 项目允许的键；有不认识的键就丢弃该项（拼错的 `onclick` 不该悄悄变成「没有动作」）。
  private static let itemKeys: Set<String> = ["id", "text", "icon", "iconFile", "color", "tooltip", "onClick"]
  /// `id` 的字符上限。
  private static let idLimit = 64
  /// 每种动作允许的键；`type` 之外的键不在表里就丢弃该项。
  private static let actionKeys: [String: Set<String>] = [
    "copy": ["type", "text", "concealed"],
    "terminal": ["type", "text", "mode"],
    "openURL": ["type", "url"],
    "openPanel": ["type", "view"],
    "refresh": ["type"],
    "feature": ["type", "code", "text"],
  ]

  // MARK: stdout

  /// 见 `ToolBarProtocol.parse`。
  static func parse(_ data: Data, pluginDirectory: URL?, itemLimit: Int) throws -> ToolBarOutput {
    guard data.count <= ToolBarProtocol.stdoutLimit else { throw ToolBarError.outputTooLarge }
    guard data.contains(where: { !isJSONWhitespace($0) }) else { return ToolBarOutput() }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw ToolBarError.invalidOutput(L("不是有效的 JSON"))
    }
    guard let root = object as? [String: Any] else {
      throw ToolBarError.invalidOutput(L("外层必须是 JSON 对象"))
    }
    var rawItems: [Any] = []
    if let value = root["items"], !(value is NSNull) {
      guard let array = value as? [Any] else { throw ToolBarError.invalidOutput(L("items 必须是数组")) }
      rawItems = array
    }
    // 先逐项校验再取前 N 项：被丢弃的坏项不占名额。
    var items: [ToolBarItem] = []
    for raw in rawItems {
      guard items.count < itemLimit else { break }
      if let item = parseItem(raw, pluginDirectory: pluginDirectory) { items.append(item) }
    }
    return ToolBarOutput(items: items, ttl: parseTTL(root["ttl"]))
  }

  /// JSON 允许的空白字节。全空白的 stdout 视为「没有项目」，而不是格式错误。
  private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
  }

  /// `ttl`：5–3600 的整数；类型不对或越界当作没给。
  private static func parseTTL(_ value: Any?) -> Int? {
    guard let number = integer(value), ToolBarProtocol.ttlRange.contains(number) else { return nil }
    return number
  }

  /// 校验一个项目；任何字段不合格（未知键、类型不对、超限、动作无效）返回 nil，由调用方丢弃整项。
  /// 例外：`icon`、`iconFile`、`color`、`tooltip` 这些纯装饰字段无效时只忽略该字段，文字和动作照常显示。
  private static func parseItem(_ raw: Any, pluginDirectory: URL?) -> ToolBarItem? {
    guard let object = raw as? [String: Any], Set(object.keys).isSubset(of: itemKeys) else { return nil }
    var item = ToolBarItem()
    if let value = present(object["id"]) {
      guard let id = value as? String, id.count <= idLimit, !ToolTextRules.containsControlCharacters(id) else {
        return nil
      }
      item.id = id
    }
    if let value = present(object["text"]) {
      // 状态条文字必须单行且不超长；这里不截断，截断会悄悄改变脚本想表达的内容。
      guard let text = value as? String, text.count <= ToolBarProtocol.textLimit,
        !ToolTextRules.containsControlCharacters(text)
      else { return nil }
      if !text.trimmingCharacters(in: .whitespaces).isEmpty { item.text = text }
    }
    if let symbol = present(object["icon"]) as? String, isValidSymbol(symbol) { item.symbol = symbol }
    if let path = present(object["iconFile"]) as? String, let pluginDirectory {
      item.iconFile = resolveIconFile(path, in: pluginDirectory)
    }
    // 没有文字也没有图标的项目没有可画的内容。
    guard item.text != nil || item.symbol != nil || item.iconFile != nil else { return nil }
    if let color = present(object["color"]) as? String { item.color = parseColor(color) }
    if let tooltip = present(object["tooltip"]) as? String { item.tooltip = clampTooltip(tooltip) }
    if let value = present(object["onClick"]) {
      guard let action = parseAction(value) else { return nil }
      item.action = action
    }
    return item
  }

  /// JSON 的 `null` 等同于没写这个键。
  private static func present(_ value: Any?) -> Any? {
    value is NSNull ? nil : value
  }

  // MARK: 字段

  /// SF Symbol 名：`^[a-z0-9.]{1,64}$`。
  private static func isValidSymbol(_ name: String) -> Bool {
    guard (1...ToolBarProtocol.symbolLimit).contains(name.utf8.count) else { return false }
    return name.unicodeScalars.allSatisfy { ToolTextRules.isLowerAlphanumeric($0) || $0 == "." }
  }

  /// `iconFile`：规则同清单 `icon`（相对路径、无 `..`、扩展名白名单），再解析符号链接，
  /// 必须落在插件目录内且是普通文件；通过后返回解析后的绝对路径，否则 nil。
  /// 符号链接解析是必须的：脚本输出是不可信数据，`icons/x.svg -> /etc/...` 之类不能让宿主去读目录外的文件。
  private static func resolveIconFile(_ path: String, in pluginDirectory: URL) -> String? {
    guard !path.isEmpty, !path.hasPrefix("/"), path.count <= ToolManifestLimits.pathCharacters,
      !ToolTextRules.containsControlCharacters(path), !path.split(separator: "/").contains("..") else { return nil }
    guard ToolManifestLimits.iconExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
    guard let root = ToolPluginDigest.canonicalPath(pluginDirectory.path),
      let resolved = ToolPluginDigest.canonicalPath((root as NSString).appendingPathComponent(path))
    else { return nil }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard resolved.hasPrefix(prefix), resolved.count > prefix.count else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return nil
    }
    return resolved
  }

  /// `#RRGGBB` / `#RRGGBBAA` 或颜色令牌；其它写法返回 nil。
  private static func parseColor(_ text: String) -> ToolBarColor? {
    if let token = ToolBarColorToken(rawValue: text) { return .token(token) }
    guard text.hasPrefix("#"), text.count == 7 || text.count == 9 else { return nil }
    let digits = text.dropFirst()
    guard digits.unicodeScalars.allSatisfy({ ToolTextRules.isDigit($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }),
      let value = UInt32(digits, radix: 16)
    else { return nil }
    let hasAlpha = digits.count == 8
    let rgb = hasAlpha ? value >> 8 : value
    let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
    return .rgba(
      red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255, alpha: alpha)
  }

  /// tooltip 超过上限截断并以 `…` 结尾；换行保留，其它控制字符换成空格。
  private static func clampTooltip(_ text: String) -> String {
    var cleaned = String(
      String.UnicodeScalarView(text.unicodeScalars.map { $0 != "\n" && ToolTextRules.isControl($0) ? " " : $0 }))
    if cleaned.count > ToolBarProtocol.tooltipLimit {
      cleaned = String(cleaned.prefix(ToolBarProtocol.tooltipLimit - 1)) + "…"
    }
    return cleaned
  }

  // MARK: onClick

  /// 校验 `onClick`：必须是对象，`type` 在白名单内，键只能是该类型声明过的；任何一处不符返回 nil。
  private static func parseAction(_ value: Any) -> ToolBarAction? {
    guard let object = value as? [String: Any], let type = object["type"] as? String,
      let allowed = actionKeys[type], Set(object.keys).isSubset(of: allowed)
    else { return nil }
    switch type {
    case "copy":
      guard let text = actionText(object["text"]) else { return nil }
      var concealed = false
      if let flag = present(object["concealed"]) {
        guard let parsed = boolean(flag) else { return nil }
        concealed = parsed
      }
      return .copy(text: text, concealed: concealed)
    case "terminal":
      guard let text = actionText(object["text"]) else { return nil }
      var mode = ToolBarTerminalMode.insert
      if let raw = present(object["mode"]) {
        guard let name = raw as? String, let parsed = ToolBarTerminalMode(rawValue: name) else { return nil }
        mode = parsed
      }
      return .terminal(text: text, mode: mode)
    case "openURL":
      guard let string = object["url"] as? String, !ToolTextRules.containsControlCharacters(string),
        !string.contains(where: \.isWhitespace)
      else { return nil }
      do {
        return .openURL(try ToolBridgeValidator.openableURL(string))
      } catch {
        return nil
      }
    case "openPanel":
      guard let view = object["view"] as? String, ToolManifestValidator.isValidCode(view) else { return nil }
      return .openPanel(viewID: view)
    case "refresh":
      return .refresh
    default:
      guard let code = object["code"] as? String, ToolManifestValidator.isValidCode(code) else { return nil }
      var text: String?
      if let raw = present(object["text"]) {
        guard let string = raw as? String, string.utf8.count <= ToolBarProtocol.actionTextLimit else { return nil }
        text = string
      }
      return .feature(code: code, text: text)
    }
  }

  /// `copy` / `terminal` 的文本：非空且不超过 64 KiB（字节）。超限不截断：截断后的命令会悄悄变成另一条命令。
  private static func actionText(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty, text.utf8.count <= ToolBarProtocol.actionTextLimit else {
      return nil
    }
    return text
  }

  /// 真正的 JSON 布尔；JSONSerialization 把 0 / 1 也桥接成 NSNumber，要排除。
  private static func boolean(_ value: Any) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  /// 能放进 Int 的 JSON 整数（排除布尔与小数）。
  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
    return Int(double)
  }

  // MARK: stdin 与环境变量

  /// 见 `ToolBarProtocol.stdinData`。
  static func stdinData(viewID: String, trigger: ToolBarTrigger, context: ToolBarContext) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(BarStdinPayload(view: viewID, trigger: trigger, context: context))
    } catch {
      // 只有字符串、布尔和 nil，编码不会失败；真失败了给脚本一个空对象，比抛错中断整条栏更稳。
      assertionFailure("bar stdin 编码失败：\(error)")
      return Data("{}".utf8)
    }
  }

  /// 见 `ToolBarProtocol.environment`。
  static func environment(viewID: String, trigger: ToolBarTrigger, context: ToolBarContext) -> [String: String] {
    var environment = ["ASTER_VIEW": viewID, "ASTER_TRIGGER": trigger.rawValue]
    if let branch = context.branch, !branch.isEmpty { environment["ASTER_BRANCH"] = branch }
    return environment.mapValues(ScriptToolProtocol.environmentValue)
  }
}

/// bar 脚本的 stdin。手写编码是为了把缺省值写成 `null` 而不是省略，脚本可以直接按键取值。
private struct BarStdinPayload: Encodable {
  let view: String
  let trigger: ToolBarTrigger
  let context: ToolBarContext

  private enum CodingKeys: String, CodingKey {
    case view, trigger, context
  }

  private enum ContextKeys: String, CodingKey {
    case workingDirectory, isRemote, locale, appearance, branch, tabID, paneID, agent
  }

  /// 按文档结构写出，可选值写 `null`。
  func encode(to encoder: any Encoder) throws {
    var root = encoder.container(keyedBy: CodingKeys.self)
    try root.encode(view, forKey: .view)
    try root.encode(trigger, forKey: .trigger)
    var values = root.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
    try values.encode(context.workingDirectory, forKey: .workingDirectory)
    try values.encode(context.isRemote, forKey: .isRemote)
    try values.encode(context.locale, forKey: .locale)
    try values.encode(context.appearance, forKey: .appearance)
    try values.encode(context.branch, forKey: .branch)
    try values.encode(context.tabID, forKey: .tabID)
    try values.encode(context.paneID, forKey: .paneID)
    try values.encode(context.agent, forKey: .agent)
  }
}
