// 桥接请求的解析与校验：版本、方法、参数结构与总大小，授权，参数取值与上限，地址与域名检查，调用频率。
import Foundation

/// 请求解析与校验。所有失败都抛 `ToolBridgeError`，应用层直接把 `replyString` 回给页面。
/// 参数取值的约定：缺失或为 `null` 且必填 → `invalid_params`；类型不对 → `invalid_params`；
/// 字节数超限 → `payload_too_large`。
public enum ToolBridgeValidator {
  /// `net.fetch` 允许的方法（大写）。
  public static let fetchMethods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

  /// 解析 WebKit 传来的消息体（Foundation 对象）：必须是 JSON 对象、序列化后 ≤ 2 MiB、`v` 恰好为 1、
  /// `method` 是已知方法、`params` 缺省、为 null 或为对象。其余顶层字段忽略。
  public static func parse(_ body: Any) throws -> ToolBridgeRequest {
    guard JSONSerialization.isValidJSONObject(body) else {
      throw ToolBridgeError.invalidParams(L("消息不是 JSON 对象"))
    }
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: body)
    } catch {
      throw ToolBridgeError.invalidParams(L("消息不是 JSON 对象"))
    }
    guard data.count <= ToolBridgeProtocol.maximumRequestBytes else { throw ToolBridgeError.payloadTooLarge }
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw ToolBridgeError.invalidParams(L("消息不是 JSON 对象"))
    }
    guard case .object(let object) = value else { throw ToolBridgeError.invalidParams(L("消息不是 JSON 对象")) }
    // `v` 必须恰好是数字 1：`1.5`、`true`、`"1"` 都按不支持的版本处理。
    guard case .number(let version)? = object["v"], version == Double(ToolBridgeProtocol.version) else {
      throw ToolBridgeError.unsupportedVersion
    }
    guard case .string(let name)? = object["method"] else { throw ToolBridgeError.invalidParams("method") }
    guard let method = ToolBridgeMethod(rawValue: name) else {
      throw ToolBridgeError.unknownMethod(String(name.prefix(64)))
    }
    switch object["params"] {
    case nil, .null?: return ToolBridgeRequest(method: method)
    case .object(let params)?: return ToolBridgeRequest(method: method, params: params)
    default: throw ToolBridgeError.invalidParams("params")
    }
  }

  /// 没授予所需权限就拒绝。
  public static func authorize(_ request: ToolBridgeRequest, granted: Set<ToolPermission>) throws {
    if let permission = request.method.requiredPermission, !granted.contains(permission) {
      throw ToolBridgeError.permissionDenied(permission)
    }
  }

  // MARK: 通用取值

  /// 取字符串参数并限制 UTF-8 字节数。
  public static func string(
    _ params: [String: JSONValue],
    _ key: String,
    maximumBytes: Int,
    required: Bool = true
  ) throws -> String? {
    guard let value = try present(params, key, required: required) else { return nil }
    guard let text = value.stringValue else { throw ToolBridgeError.invalidParams(key) }
    guard text.utf8.count <= maximumBytes else { throw ToolBridgeError.payloadTooLarge }
    return text
  }

  /// 取整数参数：必须是整数值（`1.5` 不行），给了 `range` 时还要在范围内。
  public static func int(
    _ params: [String: JSONValue],
    _ key: String,
    range: ClosedRange<Int>? = nil,
    required: Bool = true
  ) throws -> Int? {
    guard let value = try present(params, key, required: required) else { return nil }
    guard case .number(let number) = value, number.rounded() == number, abs(number) < 9_007_199_254_740_992 else {
      throw ToolBridgeError.invalidParams(key)
    }
    let integer = Int(number)
    if let range, !range.contains(integer) { throw ToolBridgeError.invalidParams(key) }
    return integer
  }

  /// 取数字参数（可带小数）。
  public static func double(_ params: [String: JSONValue], _ key: String, required: Bool = true) throws -> Double? {
    guard let value = try present(params, key, required: required) else { return nil }
    guard let number = value.doubleValue else { throw ToolBridgeError.invalidParams(key) }
    return number
  }

  /// 取布尔参数；默认可选。
  public static func bool(_ params: [String: JSONValue], _ key: String, required: Bool = false) throws -> Bool? {
    guard let value = try present(params, key, required: required) else { return nil }
    guard let flag = value.boolValue else { throw ToolBridgeError.invalidParams(key) }
    return flag
  }

  /// 取对象参数。
  public static func object(
    _ params: [String: JSONValue],
    _ key: String,
    required: Bool = true
  ) throws -> [String: JSONValue]? {
    guard let value = try present(params, key, required: required) else { return nil }
    guard let object = value.objectValue else { throw ToolBridgeError.invalidParams(key) }
    return object
  }

  /// 取数组参数，限制项数。
  public static func array(
    _ params: [String: JSONValue],
    _ key: String,
    maximumCount: Int,
    required: Bool = true
  ) throws -> [JSONValue]? {
    guard let value = try present(params, key, required: required) else { return nil }
    guard let array = value.arrayValue, array.count <= maximumCount else { throw ToolBridgeError.invalidParams(key) }
    return array
  }

  /// 取字符串数组：限制项数，每项必须是字符串并限制 UTF-8 字节数。
  public static func stringArray(
    _ params: [String: JSONValue],
    _ key: String,
    maximumCount: Int,
    maximumBytesEach: Int,
    required: Bool = true
  ) throws -> [String]? {
    guard let array = try array(params, key, maximumCount: maximumCount, required: required) else { return nil }
    return try array.map { element in
      guard let text = element.stringValue else { throw ToolBridgeError.invalidParams(key) }
      guard text.utf8.count <= maximumBytesEach else { throw ToolBridgeError.payloadTooLarge }
      return text
    }
  }

  /// 取「字符串 → 字符串」对象（例如请求头）：限制项数，键和值都必须是字符串并限制 UTF-8 字节数。
  public static func stringDictionary(
    _ params: [String: JSONValue],
    _ key: String,
    maximumCount: Int,
    maximumBytesEach: Int,
    required: Bool = true
  ) throws -> [String: String]? {
    guard let object = try object(params, key, required: required) else { return nil }
    guard object.count <= maximumCount else { throw ToolBridgeError.invalidParams(key) }
    var result: [String: String] = [:]
    for (name, value) in object {
      guard let text = value.stringValue else { throw ToolBridgeError.invalidParams(key) }
      guard name.utf8.count <= maximumBytesEach, text.utf8.count <= maximumBytesEach else {
        throw ToolBridgeError.payloadTooLarge
      }
      result[name] = text
    }
    return result
  }

  /// 取任意 JSON 值（例如 `storage.set` 的 value），限制编码后的字节数。`null` 是合法值，只有缺失才算没有。
  public static func value(
    _ params: [String: JSONValue],
    _ key: String,
    maximumBytes: Int,
    required: Bool = true
  ) throws -> JSONValue? {
    guard let value = params[key] else {
      if required { throw ToolBridgeError.invalidParams(key) }
      return nil
    }
    guard try encodedByteCount(value) <= maximumBytes else { throw ToolBridgeError.payloadTooLarge }
    return value
  }

  /// JSON 值编码后的 UTF-8 字节数，用于存储配额（存储总量 ≤ 5 MiB）。
  public static func encodedByteCount(_ value: JSONValue) throws -> Int {
    do {
      return try JSONEncoder().encode(value).count
    } catch {
      throw ToolBridgeError.invalidParams("value")
    }
  }

  // MARK: 方法专用

  /// `storage.*` 的 `key`：非空、≤ 128 字节。
  public static func storageKey(_ params: [String: JSONValue]) throws -> String {
    guard let key = try string(params, "key", maximumBytes: ToolBridgeProtocol.maximumStorageKeyBytes),
      !key.isEmpty
    else { throw ToolBridgeError.invalidParams("key") }
    return key
  }

  /// `clipboard.writeText`、`terminal.insert` 的 `text`：≤ 1 MiB。
  public static func text(_ params: [String: JSONValue]) throws -> String {
    guard let text = try string(params, "text", maximumBytes: ToolBridgeProtocol.maximumTextBytes) else {
      throw ToolBridgeError.invalidParams("text")
    }
    return text
  }

  /// `ui.setHeight` 的 `height`：任意数字，四舍五入后收进 120–800。页面常按布局算出小数或越界的高度，
  /// 收拢比报错更有用；不是数字才报 `invalid_params`。
  public static func height(_ params: [String: JSONValue]) throws -> Int {
    guard let number = try double(params, "height"), number.isFinite else {
      throw ToolBridgeError.invalidParams("height")
    }
    let range = ToolUIConfig.heightRange
    return Int(min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
  }

  /// `net.fetch` 的地址：只允许 https，主机须匹配已授权域名。主机里有百分号编码时拒绝，避免检查与实际请求不一致。
  public static func fetchURL(_ string: String, allowedHosts: [String]) throws -> URL {
    guard let components = URLComponents(string: string), components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty, components.percentEncodedHost == host, let url = components.url
    else { throw ToolBridgeError.invalidParams(L("只允许 https 地址")) }
    guard isHostAllowed(host, patterns: allowedHosts) else {
      throw ToolBridgeError.invalidParams(L("域名未授权：\(host)"))
    }
    return url
  }

  /// `shell.openURL` 的地址：只允许 http 与 https，且必须有主机。
  public static func openableURL(_ string: String) throws -> URL {
    guard let components = URLComponents(string: string), let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty, let url = components.url
    else { throw ToolBridgeError.invalidParams(L("只允许 http 或 https 地址")) }
    return url
  }

  /// 主机是否在允许列表里（大小写无关，忽略主机末尾的一个点）。`*.example.com` 匹配任意层子域名，
  /// 不匹配 `example.com` 本身，也不匹配 `badexample.com`。
  public static func isHostAllowed(_ host: String, patterns: [String]) -> Bool {
    var host = host.lowercased()
    if host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty else { return false }
    return patterns.contains { pattern in
      let pattern = pattern.lowercased()
      guard pattern.hasPrefix("*.") else { return host == pattern }
      let suffix = String(pattern.dropFirst())
      return suffix.count > 1 && host.count > suffix.count && host.hasSuffix(suffix)
    }
  }

  /// 取出存在且不为 null 的参数；缺失时按 `required` 报错或返回 nil。
  private static func present(_ params: [String: JSONValue], _ key: String, required: Bool) throws -> JSONValue? {
    guard let value = params[key], !value.isNull else {
      if required { throw ToolBridgeError.invalidParams(key) }
      return nil
    }
    return value
  }
}

/// 页面调用频率限制：滑动窗口内最多 `limit` 次（默认每秒 50 次）。值类型，由持有页面的控制器在同一线程使用。
public struct ToolBridgeRateLimiter: Sendable {
  public let limit: Int
  public let window: TimeInterval
  /// 窗口内已放行调用的时间点（单调时钟秒数），按时间先后排列。
  private var recent: [TimeInterval] = []

  /// 每 `window` 秒最多放行 `limit` 次调用。
  public init(limit: Int = ToolBridgeProtocol.maximumCallsPerSecond, window: TimeInterval = 1) {
    self.limit = limit
    self.window = window
  }

  /// 记录一次调用；窗口内已满时返回 false，这次调用不计入。`now` 应来自单调时钟（如 `ProcessInfo.systemUptime`）。
  public mutating func allow(now: TimeInterval) -> Bool {
    let windowStart = now - window
    if let firstKept = recent.firstIndex(where: { $0 > windowStart }) {
      recent.removeFirst(firstKept)
    } else {
      recent.removeAll(keepingCapacity: true)
    }
    guard recent.count < limit else { return false }
    recent.append(now)
    return true
  }
}
