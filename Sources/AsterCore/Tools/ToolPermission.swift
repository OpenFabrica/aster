// 工具插件可以申请的权限与风险等级。清单校验、安装确认、桥接授权与设置页共用这一份定义。
import Foundation

/// 插件在清单 `permissions` 里声明的能力。没声明就不能用；私有存储隐式授予，不在此列。
public enum ToolPermission: String, CaseIterable, Codable, Hashable, Sendable {
  case clipboardRead = "clipboard.read"
  case clipboardWrite = "clipboard.write"
  case terminalRead = "terminal.read"
  case terminalInsert = "terminal.insert"
  case filesRead = "files.read"
  case network
  case notify
  case exec

  /// 风险等级决定安装确认里的颜色与排序：高风险排最前。
  public var risk: ToolPermissionRisk {
    switch self {
    case .clipboardWrite, .terminalInsert, .notify: .low
    case .clipboardRead, .terminalRead, .filesRead, .network: .medium
    case .exec: .high
    }
  }

  /// 安装确认与设置页显示的说明文字。
  public var localizedTitle: String {
    switch self {
    case .clipboardRead: L("读取剪贴板")
    case .clipboardWrite: L("写入剪贴板")
    case .terminalRead: L("读取终端选中的文字")
    case .terminalInsert: L("把文字预填到终端（不会自动回车）")
    case .filesRead: L("读取你选择或传入的文件")
    case .network: L("访问网络")
    case .notify: L("发送系统通知")
    case .exec: L("运行插件自带的程序")
    }
  }
}

/// 权限风险等级。`Comparable` 让调用方可以直接按风险排序。
public enum ToolPermissionRisk: String, Codable, Comparable, Sendable {
  case low
  case medium
  case high

  private var rank: Int {
    switch self {
    case .low: 0
    case .medium: 1
    case .high: 2
    }
  }

  public static func < (lhs: ToolPermissionRisk, rhs: ToolPermissionRisk) -> Bool {
    lhs.rank < rhs.rank
  }
}
