// 界面扩展目录里的一项：某个插件声明的一个视图，连同生效位置、启用状态与运行所需信息。
// 由 ToolCenter 在每次目录重建时生成；窗口的 WorkspaceExtensionHost 按它挂载与调度。
import AsterCore
import Foundation

/// 一个可挂载的视图。
struct ToolViewEntry: Equatable, Identifiable {
  let pluginID: String
  let pluginName: String
  let source: ToolPluginSource
  /// 显示用的视图声明（内置插件的标题已翻译）。
  let contribution: ToolViewContribution
  /// 生效位置：用户改过取用户的，否则取清单缺省。
  let slot: ToolViewSlot
  /// 用户没有关掉这个视图。
  let isEnabled: Bool
  /// 插件状态；`needsApproval` 时 bar 显示「需要授权」，不跑脚本。
  let status: ToolPluginStatus
  /// 视图图标（绝对路径），没有则用插件图标。
  let iconPath: String?
  /// 插件根目录；内置原生插件没有。
  let pluginDirectory: URL?
  /// 可用权限（内置全给；其它为「声明 ∩ 已授权」）。
  let permissions: Set<ToolPermission>

  /// `<pluginID>/view:<viewID>`：调度缓存、会话缓存与 Inspector 选中态的键。
  var id: String { Self.makeID(pluginID: pluginID, viewID: contribution.id) }

  /// 应该挂到窗口上：视图启用、插件没停用、位置已实现。需要授权的视图也挂（显示授权提示）。
  var isMountable: Bool { isEnabled && status != .disabled && slot.isImplemented }

  /// 组合视图 id。
  static func makeID(pluginID: String, viewID: String) -> String {
    "\(pluginID)/view:\(viewID)"
  }
}
