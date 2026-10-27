// 网页工具桥接协议 v1：常量、方法表与所需权限、请求与错误模型。解析与校验在 ToolBridgeValidator.swift，WebKit 接线在应用层。
import Foundation

/// 桥接协议常量。
public enum ToolBridgeProtocol {
  public static let version = 1
  /// `window.webkit.messageHandlers.<name>`。
  public static let messageHandlerName = "aster"
  /// 插件页面使用的 URL scheme。
  public static let scheme = "aster-plugin"
  public static let maximumRequestBytes = 2 * 1_048_576
  public static let maximumTextBytes = 1_048_576
  public static let maximumStorageKeyBytes = 128
  public static let maximumStorageBytes = 5 * 1_048_576
  public static let maximumFileReadBytes = 10 * 1_048_576
  public static let maximumFetchResponseBytes = 5 * 1_048_576
  public static let fetchTimeout: TimeInterval = 15
  /// 每个页面每秒最多的调用次数。
  public static let maximumCallsPerSecond = 50
  /// 每个响应都带的 CSP。
  public static let contentSecurityPolicy =
    "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
    + "font-src 'self' data:; media-src 'self' data: blob:; connect-src 'none'; object-src 'none'; "
    + "frame-src 'none'; base-uri 'none'; form-action 'none'"
}

/// 桥接方法。原始值就是 JS 侧的 `method` 字符串。
public enum ToolBridgeMethod: String, CaseIterable, Sendable {
  case toolInput = "tool.input"
  case setHeight = "ui.setHeight"
  case close = "ui.close"
  case storageGet = "storage.get"
  case storageSet = "storage.set"
  case storageRemove = "storage.remove"
  case storageKeys = "storage.keys"
  case clipboardReadText = "clipboard.readText"
  case clipboardWriteText = "clipboard.writeText"
  case terminalInsert = "terminal.insert"
  case terminalSelection = "terminal.selection"
  case filesPick = "files.pick"
  case filesRead = "files.read"
  case netFetch = "net.fetch"
  case notify
  case openURL = "shell.openURL"

  /// 调用这个方法需要的权限；nil 表示不需要声明。
  public var requiredPermission: ToolPermission? {
    switch self {
    case .toolInput, .setHeight, .close, .storageGet, .storageSet, .storageRemove, .storageKeys, .openURL: nil
    case .clipboardReadText: .clipboardRead
    case .clipboardWriteText: .clipboardWrite
    case .terminalInsert: .terminalInsert
    case .terminalSelection: .terminalRead
    case .filesPick, .filesRead: .filesRead
    case .netFetch: .network
    case .notify: .notify
    }
  }
}

/// 一条已解析的请求。
public struct ToolBridgeRequest: Equatable, Sendable {
  public let method: ToolBridgeMethod
  public let params: [String: JSONValue]

  public init(method: ToolBridgeMethod, params: [String: JSONValue] = [:]) {
    self.method = method
    self.params = params
  }
}

/// 桥接错误。`code` 是 snake_case，JS 侧据此区分。
public enum ToolBridgeError: Error, Equatable, Sendable {
  case unsupportedVersion
  case unknownMethod(String)
  case invalidParams(String)
  case permissionDenied(ToolPermission)
  case payloadTooLarge
  case rateLimited
  case unavailable(String)
  case failed(String)

  public var code: String {
    switch self {
    case .unsupportedVersion: "unsupported_version"
    case .unknownMethod: "unknown_method"
    case .invalidParams: "invalid_params"
    case .permissionDenied: "permission_denied"
    case .payloadTooLarge: "payload_too_large"
    case .rateLimited: "rate_limited"
    case .unavailable: "unavailable"
    case .failed: "failed"
    }
  }

  public var message: String {
    switch self {
    case .unsupportedVersion: L("不支持的桥接协议版本")
    case .unknownMethod(let method): L("未知方法：\(method)")
    case .invalidParams(let reason): L("参数无效：\(reason)")
    case .permissionDenied(let permission): L("未声明权限：\(permission.rawValue)")
    case .payloadTooLarge: L("数据太大")
    case .rateLimited: L("调用太频繁")
    case .unavailable(let reason): reason
    case .failed(let reason): reason
    }
  }

  /// 回给 WebKit 的错误字符串：`"<code>: <message>"`。
  public var replyString: String { "\(code): \(message)" }
}
