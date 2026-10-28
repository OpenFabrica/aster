// 窗口向 Inspector 提供插件 panel 视图的接口：WorkspaceExtensionHost 实现，DetailsPanelViewController 使用。
// 会话由窗口级缓存长期持有，详情面板每次重建只借用，不重新加载网页。
import AsterCore
import Combine
import Foundation

/// 插件 panel 视图的提供方。
@MainActor
protocol ToolPanelProviding: AnyObject {
  /// Inspector 页签里可选的插件面板（位置是 `inspector.panel`、可挂载），按插件显示顺序。
  var inspectorPanelEntries: [ToolViewEntry] { get }
  /// 借出视图的会话：第一次创建，之后复用同一个控制器；视图不存在或不可挂载时为 nil。
  func panelSession(for entryID: String) -> ToolSessionViewController?
  /// `inspectorPanelEntries` 变化时发出（插件启用、停用、改位置、清单变化）。
  var panelEntriesChanged: AnyPublisher<Void, Never> { get }
}
