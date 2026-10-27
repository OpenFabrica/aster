// 桥接数据在 Swift 与 WebKit 之间的转换：JSONValue → Foundation 对象，以及参数取值的小工具。
import AsterCore
import Foundation

extension JSONValue {
  /// 转成 WebKit 回复与 `callAsyncJavaScript` 参数能接受的 Foundation 对象
  /// （NSNull、NSNumber、NSString、NSArray、NSDictionary）。
  var foundationObject: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): NSNumber(value: value)
    case .number(let value): NSNumber(value: value)
    case .string(let value): value
    case .array(let values): values.map(\.foundationObject)
    case .object(let members): members.mapValues(\.foundationObject)
    }
  }
}

/// 桥接参数取值。缺省或类型不对时抛 `invalid_params`，错误里只带字段名。
enum ToolBridgeParams {
  /// 可选布尔参数；缺省或 null 时返回 `defaultValue`。
  static func bool(_ params: [String: JSONValue], _ key: String, default defaultValue: Bool) throws -> Bool {
    guard let value = params[key], !value.isNull else { return defaultValue }
    guard let flag = value.boolValue else { throw ToolBridgeError.invalidParams(key) }
    return flag
  }

  /// 必填、有限的数字参数。
  static func number(_ params: [String: JSONValue], _ key: String) throws -> Double {
    guard let number = params[key]?.doubleValue, number.isFinite else { throw ToolBridgeError.invalidParams(key) }
    return number
  }

  /// 必填字符串参数，限制 UTF-8 字节数（超出抛 `payload_too_large`）。
  static func requiredString(_ params: [String: JSONValue], _ key: String, maximumBytes: Int) throws -> String {
    guard let text = try ToolBridgeValidator.string(params, key, maximumBytes: maximumBytes) else {
      throw ToolBridgeError.invalidParams(key)
    }
    return text
  }

  /// 可选的字符串数组参数；缺省或 null 时返回空数组。
  static func stringArray(_ params: [String: JSONValue], _ key: String, maximumCount: Int) throws -> [String] {
    guard let value = params[key], !value.isNull else { return [] }
    guard let items = value.arrayValue, items.count <= maximumCount else { throw ToolBridgeError.invalidParams(key) }
    return try items.map { item in
      guard let text = item.stringValue else { throw ToolBridgeError.invalidParams(key) }
      return text
    }
  }
}
