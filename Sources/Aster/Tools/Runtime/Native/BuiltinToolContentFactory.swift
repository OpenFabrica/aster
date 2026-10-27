// 按 handler 创建内置原生工具界面。
import AppKit
import AsterCore

/// 按内置处理器创建对应的原生工具界面。
@MainActor
enum BuiltinToolContentFactory {
  /// 创建 handler 对应的界面，初始输入为 `input`。
  static func make(handler: ToolBuiltinHandler, input: ToolInput, actions: BuiltinToolActions) -> any BuiltinToolContent {
    switch handler {
    case .timestamp: TimestampToolContent(input: input, actions: actions)
    case .base64: Base64ToolContent(input: input, actions: actions)
    case .url: URLToolContent(input: input, actions: actions)
    case .hash: HashToolContent(input: input, actions: actions)
    case .uuid: UUIDToolContent(input: input, actions: actions)
    case .ports: PortsToolContent(input: input, actions: actions)
    case .json: JSONToolContent(input: input, actions: actions)
    }
  }
}
