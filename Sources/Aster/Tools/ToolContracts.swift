// 工具功能在应用层的公共接口。启动器、工具 Pane、设置页与网页运行时只经这里的类型互相调用，
// 不直接读插件目录、不直接创建进程或 WebView。字段语义见 docs/developer/tools-and-plugins.md。
import AppKit
import AsterCore
import Combine

// MARK: - 打开工具

extension Notification.Name {
  /// 请求显示工具面板（设置页按钮、命令面板等不直接依赖面板控制器的地方发出）。
  /// `object` 可以是 `ToolLaunchRequest` 包装的 `ToolLauncherRequestBox`，为空表示只打开面板。
  static let asterShowToolLauncher = Notification.Name("aster.tools.showLauncher")
}

/// 经通知传递打开请求时的包装（`Notification.object` 需要引用类型）。
@MainActor
final class ToolLauncherRequestBox {
  let request: ToolLaunchRequest

  init(request: ToolLaunchRequest) {
    self.request = request
  }
}

/// 一次打开工具的请求。
struct ToolLaunchRequest {
  let entry: ToolCatalogEntry
  var input: ToolInput
  /// 发起时的终端 Pane。往终端预填文字、读选区都只认它；nil 表示没有可用的终端。
  let origin: ToolTerminalOrigin?

  init(entry: ToolCatalogEntry, input: ToolInput, origin: ToolTerminalOrigin?) {
    self.entry = entry
    self.input = input
    self.origin = origin
  }
}

/// 发起工具的终端 Pane。弱引用会话：Pane 关闭后自然失效，迟到的写入因此不会落到别的 Pane。
@MainActor
final class ToolTerminalOrigin {
  private(set) weak var session: TerminalSession?
  let paneID: UUID

  init(session: TerminalSession, paneID: UUID) {
    self.session = session
    self.paneID = paneID
  }

  /// 会话还在。
  var isAlive: Bool { session != nil }

  /// 预填文字（bracketed paste + 粘贴保护，永不回车）。失败时返回给用户看的原因。
  func insert(_ text: String) -> String? {
    guard let session else { return L("来源终端已经关闭") }
    if session.pastePromptText(text) { return nil }
    return session.promptWriteBlocker ?? L("无法粘贴到这个终端")
  }

  /// 写入并回车执行（便笺的「发送到当前 Pane」）：走 Composer 同一条路，bracketed paste 一次写入多行，
  /// 再单独发 Return；粘贴保护与只读门禁照常生效。失败时返回给用户看的原因。
  func submit(_ text: String) -> String? {
    guard let session else { return L("来源终端已经关闭") }
    if session.submitComposerText(text) { return nil }
    return session.promptWriteBlocker ?? L("无法粘贴到这个终端")
  }

  /// 来源 Pane 当前选中的文字。
  var selectedText: String? { session?.selectedTextForAgentContext }
}

/// 承载工具界面的容器（工具面板、工具 Pane）需要提供的能力。
@MainActor
protocol ToolSessionHost: AnyObject {
  /// 工具请求关闭（`ui.close`、`none` 脚本完成、用户点关闭）。
  func toolSessionDidRequestClose(_ session: ToolSessionViewController)
  /// 工具希望的内容高度（点）；工具 Pane 可以忽略。
  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat)
  /// 在容器里显示一条短提示。
  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool)
  /// 把文字预填到来源 Pane（不回车）。成功返回 true；失败时容器负责提示原因。
  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool
  /// 把当前工具（带当前输入）改到工作区 Pane 里打开。
  func toolSessionOpenInPane(_ session: ToolSessionViewController)
  /// 在新终端标签里运行命令（脚本 `output == terminal`）。命令按 POSIX 规则转义后输入并回车。
  func toolSession(
    _ session: ToolSessionViewController,
    runInTerminal command: [String],
    workingDirectory: String?,
    environment: [String: String]
  )
  /// 弹确认框、文件选择框时挂靠的窗口。
  var toolSessionWindow: NSWindow? { get }
}

// MARK: - 网页工具

/// 运行插件需要的已解析信息，由工具中心从扫描结果与授权记录组装。
struct ToolPluginRuntimeInfo {
  let manifest: ToolManifest
  let source: ToolPluginSource
  /// 插件根目录（已解析符号链接）。
  let directory: URL
  /// `<AppSupport>/PluginData/<id>/`，可能尚未创建。
  let dataDirectory: URL
  let grantedPermissions: Set<ToolPermission>
  let grantedNetworkDomains: [String]
}

/// `WebToolViewController` 向外请求的能力；由 `ToolSessionViewController` 实现并转给容器。
@MainActor
protocol ToolWebHost: AnyObject {
  func webTool(_ controller: WebToolViewController, didRequestHeight height: CGFloat)
  func webToolDidRequestClose(_ controller: WebToolViewController)
  /// 预填到来源 Pane；失败时返回原因。
  func webTool(_ controller: WebToolViewController, insertIntoTerminal text: String) -> String?
  /// 来源 Pane 的选区。
  func webToolTerminalSelection(_ controller: WebToolViewController) -> String?
  func webTool(_ controller: WebToolViewController, showNotice text: String, isError: Bool)
  var webToolWindow: NSWindow? { get }
}

// MARK: - 设置页

/// 设置页看到的插件一览。
struct ToolPluginSummary: Equatable {
  let id: String
  let name: String
  let version: String
  let description: String?
  let source: ToolPluginSource
  /// 插件目录；内置原生工具为空字符串。
  let directory: String
  let status: ToolPluginStatus
  /// 清单声明的权限（按风险从高到低）。
  let permissions: [ToolPermission]
  let grantedPermissions: [ToolPermission]
  let networkDomains: [String]
  let featureCount: Int
  /// 内置插件不可卸载。
  var isRemovable: Bool { source != .builtin }
  var isEnabled: Bool { status != .disabled }
}

/// 扫描时发现的问题（清单无效、id 冲突、摘要失败等）。
struct ToolPluginIssue: Equatable {
  let path: String
  let message: String
}

/// 设置页使用的管理接口；`ToolCenter` 实现，测试可以替换。
@MainActor
protocol ToolManaging: AnyObject {
  var pluginSummaries: [ToolPluginSummary] { get }
  var pluginIssues: [ToolPluginIssue] { get }
  var pluginsDirectory: URL { get }
  var developmentFolders: [String] { get }
  /// 插件列表、启用状态或授权变化时发出。
  var changes: AnyPublisher<Void, Never> { get }
  /// 重新扫描（后台进行，完成后发出 `changes`）。
  func reload()
  func setEnabled(_ enabled: Bool, pluginID: String)
  /// 弹出权限确认；用户同意后写入授权并启用。返回是否同意。
  func approve(pluginID: String, window: NSWindow?) async -> Bool
  /// 从文件夹安装：校验清单、确认权限、复制到插件目录。返回插件 id。
  func installPlugin(from folder: URL, window: NSWindow?) async throws -> String
  /// 登记开发目录（不复制）：校验清单、确认权限。返回插件 id。
  func addDevelopmentFolder(_ folder: URL, window: NSWindow?) async throws -> String
  func removeDevelopmentFolder(_ path: String)
  /// 卸载：插件目录移到废纸篓，删除插件数据与 WebKit 存储；内置插件抛错。
  func uninstall(pluginID: String) async throws
}

/// 工具中心对外抛出的错误。
enum ToolCenterError: Error, Equatable, LocalizedError {
  case pluginNotFound(String)
  case notRemovable(String)
  case invalidManifest(String)
  case alreadyInstalled(String)
  case declined
  case fileOperationFailed(String)

  var errorDescription: String? {
    switch self {
    case .pluginNotFound(let id): L("找不到插件：\(id)")
    case .notRemovable(let id): L("内置插件不能卸载：\(id)")
    case .invalidManifest(let reason): L("插件清单无效：\(reason)")
    case .alreadyInstalled(let id): L("已经安装了同 id 的插件：\(id)")
    case .declined: L("已取消")
    case .fileOperationFailed(let reason): L("文件操作失败：\(reason)")
    }
  }
}
