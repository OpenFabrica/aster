// 设置页「工具」分类的桥接：工具面板快捷键、插件一览、扫描问题、开发目录与插件管理动作。
// 真值在 ToolManaging（ToolCenter）与 AppPreferences 的兼容字段里；这里不持有副本。
//
// `SettingsViewController` 只负责把消息转进来、把快照与回执送出去；它的 private 成员
// 不对这里开放，需要的能力（推送快照、toast、设置窗口）都以闭包注入。
import AppKit
import AsterCore
import Combine
import Foundation

/// 设置页「工具」分类的快照与动作处理。
@MainActor
final class SettingsToolsBridge {
  /// 本协作者处理的动作；均以 `tools.` 为前缀。
  nonisolated static let actions: Set<String> = [
    "tools.setEnabled", "tools.approve", "tools.uninstall", "tools.reveal", "tools.openPluginsFolder",
    "tools.reload", "tools.installFromFolder", "tools.addDevelopmentFolder", "tools.removeDevelopmentFolder",
    "tools.openLauncher",
  ]
  /// 工具面板全局快捷键的兼容设置键；启动器按它注册热键。
  nonisolated static let launcherShortcutKey = "tools.launcherShortcut"
  /// `tools.launcherShortcut` 的允许取值；`none` 是默认值。
  nonisolated static let launcherShortcutChoices: Set<String> = ["none", "optionSpace", "controlOptionSpace"]
  /// Quick Terminal 全局快捷键的兼容设置键；与工具面板不能选同一组合。
  nonisolated static let quickTerminalShortcutKey = "quickTerminal.shortcut"

  /// 文件夹选择框的用途，决定标题与确认按钮文字。
  enum FolderPurpose {
    case install
    case development
  }

  /// 一次异步动作的结果：是否成功，以及完成后要显示的提示。
  private struct Outcome {
    var succeeded: Bool
    var message: String?
    var isError = false
  }

  /// 立即推送一份新快照。动作完成后先推快照再发回执，网页拿到回执时页面已是新值。
  var pushSnapshot: () -> Void = {}
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }
  /// 设置窗口：确认框、文件夹选择框与授权确认都挂在它上面。
  var window: () -> NSWindow? = { nil }
  /// 设置窗口是否还开着；关闭后异步动作完成时不再推快照、不弹 toast、不发回执。
  var isPresented: () -> Bool = { true }
  /// 打开工具面板；测试注入。
  var showLauncher: @MainActor () -> Void = {
    NotificationCenter.default.post(name: .asterShowToolLauncher, object: nil)
  }
  /// 在 Finder 中选中插件目录；测试注入。
  var revealInFinder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
  /// 用 Finder 打开插件目录；测试注入。
  var openFolder: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
  /// 卸载前的原生确认，参数是插件名；测试注入。
  var confirmUninstall: @MainActor (String, NSWindow?) async -> Bool = { name, window in
    await SettingsToolsBridge.presentUninstallConfirmation(name: name, window: window)
  }
  /// 只能选目录的原生选择框；用户取消时返回 nil。测试注入。
  var chooseFolder: @MainActor (FolderPurpose, NSWindow?) async -> URL? = { purpose, window in
    await SettingsToolsBridge.presentFolderPanel(purpose, window: window)
  }

  private let tools: any ToolManaging
  private let preferences: AppPreferences
  private let fileManager: FileManager
  private var cancellables: Set<AnyCancellable> = []
  /// 已排队、尚未执行的合并推送。
  private var snapshotPending = false
  /// 正在进行的确认框 / 选择框动作；重复点击时不再弹第二个。
  private var isRunningModalAction = false

  init(
    preferences: AppPreferences,
    tools: (any ToolManaging)? = nil,
    fileManager: FileManager = .default
  ) {
    self.preferences = preferences
    self.tools = tools ?? ToolCenter.shared
    self.fileManager = fileManager
  }

  /// 订阅工具中心的变化，合并后推送新快照。重复调用无副作用。
  func start() {
    guard cancellables.isEmpty else { return }
    tools.changes
      .sink { [weak self] _ in self?.scheduleSnapshot() }
      .store(in: &cancellables)
  }

  /// 打开工具面板（网页按钮与原生回退页共用）。
  func openLauncher() {
    showLauncher()
  }

  // MARK: - 快照

  /// 网页快照的 `tools` 字段；形状见 docs/developer/tools-and-plugins.md「设置页「工具」」。
  func snapshot() -> [String: Any] {
    [
      "launcherShortcut": preferences.compatibilityString(forKey: Self.launcherShortcutKey, default: "none"),
      "quickTerminalShortcut": preferences.compatibilityString(forKey: Self.quickTerminalShortcutKey, default: "none"),
      "pluginsDirectory": tools.pluginsDirectory.path,
      "plugins": Self.displayOrder(tools.pluginSummaries).map(Self.pluginRow),
      "issues": tools.pluginIssues.map { ["path": $0.path, "message": $0.message] },
      "developmentFolders": tools.developmentFolders,
    ]
  }

  /// 一个插件的快照行。`statusReason` 只在需要确认时有值，其余为 null。
  static func pluginRow(_ plugin: ToolPluginSummary) -> [String: Any] {
    let granted = Set(plugin.grantedPermissions)
    let status: String
    var reason: Any = NSNull()
    switch plugin.status {
    case .ready: status = "ready"
    case .disabled: status = "disabled"
    case .needsApproval(let approval):
      status = "needsApproval"
      reason = approval.identifier
    }
    var description: Any = NSNull()
    if let text = plugin.description { description = text }
    return [
      "id": plugin.id,
      "name": plugin.name,
      "version": plugin.version,
      "description": description,
      "source": plugin.source.rawValue,
      "directory": plugin.directory,
      "status": status,
      "statusReason": reason,
      "enabled": plugin.isEnabled,
      "permissions": orderedByRisk(plugin.permissions).map { permission -> [String: Any] in
        [
          "id": permission.rawValue,
          "risk": permission.risk.rawValue,
          "title": permission.localizedTitle,
          "granted": granted.contains(permission),
        ]
      },
      "networkDomains": plugin.networkDomains,
      "featureCount": plugin.featureCount,
      "removable": plugin.isRemovable,
    ]
  }

  /// 展示顺序：用户安装的在前，其次开发中的，内置排最后；同组按名称、再按 id。
  static func displayOrder(_ plugins: [ToolPluginSummary]) -> [ToolPluginSummary] {
    func rank(_ source: ToolPluginSource) -> Int {
      switch source {
      case .user: 0
      case .development: 1
      case .builtin: 2
      }
    }
    return plugins.sorted { lhs, rhs in
      if rank(lhs.source) != rank(rhs.source) { return rank(lhs.source) < rank(rhs.source) }
      let order = lhs.name.localizedStandardCompare(rhs.name)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
  }

  /// 按风险从高到低排列，同级保持清单里的声明顺序。
  static func orderedByRisk(_ permissions: [ToolPermission]) -> [ToolPermission] {
    permissions.enumerated()
      .sorted { lhs, rhs in
        lhs.element.risk != rhs.element.risk ? lhs.element.risk > rhs.element.risk : lhs.offset < rhs.offset
      }
      .map(\.element)
  }

  // MARK: - 快捷键冲突

  /// 两个全局快捷键不能选同一组合（`none` 不算占用）：写入 `key = value` 会撞上另一个键的
  /// 当前值时抛 `SettingsShortcutConflict`。与这两个键无关的写入直接放行。
  static func validateShortcutChoice(
    key: String,
    value: SettingsCompatibilityValue,
    preferences: AppPreferences
  ) throws {
    let otherKey: String
    let conflict: SettingsShortcutConflict
    switch key {
    case launcherShortcutKey: (otherKey, conflict) = (quickTerminalShortcutKey, .usedByQuickTerminal)
    case quickTerminalShortcutKey: (otherKey, conflict) = (launcherShortcutKey, .usedByToolLauncher)
    default: return
    }
    guard case .string(let choice) = value, choice != "none",
      preferences.compatibilityString(forKey: otherKey, default: "none") == choice
    else { return }
    throw conflict
  }

  // MARK: - 动作

  /// 分发动作；每个动作都以 `complete(succeeded)` 结束（设置窗口关闭后完成的异步动作除外）。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    switch action {
    case "tools.setEnabled":
      guard let plugin = requirePlugin(in: payload) else { return complete(false) }
      guard let enabled = Self.strictBool(payload["enabled"]) else { return invalid(complete) }
      tools.setEnabled(enabled, pluginID: plugin.id)
      pushSnapshotNow()
      complete(true)
    case "tools.approve":
      guard let plugin = requirePlugin(in: payload) else { return complete(false) }
      runModal(complete) { [self] in
        // 用户拒绝不算错误，不提示；授权结果以随后的快照为准。
        Outcome(succeeded: await tools.approve(pluginID: plugin.id, window: window()))
      }
    case "tools.uninstall":
      guard let plugin = requirePlugin(in: payload) else { return complete(false) }
      uninstall(plugin, complete: complete)
    case "tools.reveal":
      guard let plugin = requirePlugin(in: payload) else { return complete(false) }
      reveal(plugin, complete: complete)
    case "tools.openPluginsFolder":
      openPluginsFolder(complete: complete)
    case "tools.reload":
      // 扫描在后台进行，完成后工具中心发出 changes，由合并推送刷新页面。
      tools.reload()
      toast(L("正在重新扫描插件…"), false)
      complete(true)
    case "tools.installFromFolder":
      runModal(complete) { [self] in
        guard let folder = await chooseFolder(.install, window()) else { return Outcome(succeeded: false) }
        do {
          let id = try await tools.installPlugin(from: folder, window: window())
          return Outcome(succeeded: true, message: L("已安装插件「\(displayName(id))」"))
        } catch {
          return Self.failure(error)
        }
      }
    case "tools.addDevelopmentFolder":
      runModal(complete) { [self] in
        guard let folder = await chooseFolder(.development, window()) else { return Outcome(succeeded: false) }
        do {
          let id = try await tools.addDevelopmentFolder(folder, window: window())
          return Outcome(succeeded: true, message: L("已登记开发中的插件「\(displayName(id))」"))
        } catch {
          return Self.failure(error)
        }
      }
    case "tools.removeDevelopmentFolder":
      guard let path = payload["path"] as? String, !path.isEmpty, path.utf8.count <= 4_096 else { return invalid(complete) }
      // 只认已登记的原值，网页不能借这个动作让工具中心处理任意路径。
      guard tools.developmentFolders.contains(path) else {
        toast(L("开发目录未登记：\(path)"), true)
        return complete(false)
      }
      tools.removeDevelopmentFolder(path)
      pushSnapshotNow()
      complete(true)
    case "tools.openLauncher":
      openLauncher()
      complete(true)
    default:
      toast(L("“\(action)”尚无可用的 macOS 操作"), true)
      complete(false)
    }
  }

  /// 参数类型不对：提示并以失败结束。
  private func invalid(_ complete: (Bool) -> Void) {
    toast(L("参数无效"), true)
    complete(false)
  }

  /// 取动作参数里的插件：`id` 必须是字符串且在当前插件列表里；不满足时已经提示过。
  private func requirePlugin(in payload: [String: Any]) -> ToolPluginSummary? {
    guard let id = payload["id"] as? String, !id.isEmpty, id.utf8.count <= 256 else {
      toast(L("参数无效"), true)
      return nil
    }
    guard let plugin = tools.pluginSummaries.first(where: { $0.id == id }) else {
      toast(ToolCenterError.pluginNotFound(id).localizedDescription, true)
      return nil
    }
    return plugin
  }

  /// 卸载用户安装的插件：先原生确认，再交给工具中心。内置与开发中的插件不走这里——
  /// 开发目录是用户自己的源码，绝不能被「卸载」移到废纸篓，只能在「开发」里移除登记。
  private func uninstall(_ plugin: ToolPluginSummary, complete: @escaping (Bool) -> Void) {
    switch plugin.source {
    case .builtin:
      toast(ToolCenterError.notRemovable(plugin.id).localizedDescription, true)
      return complete(false)
    case .development:
      toast(L("开发中的插件不会被卸载，请在「开发」里移除它的目录"), true)
      return complete(false)
    case .user:
      break
    }
    runModal(complete) { [self] in
      guard await confirmUninstall(plugin.name, window()) else { return Outcome(succeeded: false) }
      do {
        try await tools.uninstall(pluginID: plugin.id)
        return Outcome(succeeded: true, message: L("已卸载插件「\(plugin.name)」"))
      } catch {
        return Self.failure(error)
      }
    }
  }

  /// 在 Finder 中显示插件目录；内置原生工具没有目录。
  private func reveal(_ plugin: ToolPluginSummary, complete: (Bool) -> Void) {
    guard !plugin.directory.isEmpty else {
      toast(L("内置原生工具没有插件目录"), false)
      return complete(false)
    }
    guard fileManager.fileExists(atPath: plugin.directory) else {
      toast(L("插件目录不存在：\(plugin.directory)"), true)
      return complete(false)
    }
    revealInFinder(URL(fileURLWithPath: plugin.directory))
    complete(true)
  }

  /// 打开插件目录；目录还不存在时先创建，让用户随时能把插件拖进去。
  private func openPluginsFolder(complete: (Bool) -> Void) {
    let directory = tools.pluginsDirectory
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      toast(ToolCenterError.fileOperationFailed(error.localizedDescription).localizedDescription, true)
      return complete(false)
    }
    openFolder(directory)
    complete(true)
  }

  /// 运行一个会弹确认框或选择框的异步动作。同一时间只允许一个，重复点击直接以失败结束；
  /// 完成时设置窗口已关闭就不再回调（不推快照、不提示、不发回执）。
  private func runModal(_ complete: @escaping (Bool) -> Void, _ body: @escaping @MainActor () async -> Outcome) {
    guard !isRunningModalAction else { return complete(false) }
    isRunningModalAction = true
    // 动作体本来就持有 self，这里直接强引用；确认框结束后很快释放。
    Task { @MainActor in
      let outcome = await body()
      isRunningModalAction = false
      guard isPresented() else { return }
      pushSnapshotNow()
      if let message = outcome.message { toast(message, outcome.isError) }
      complete(outcome.succeeded)
    }
  }

  /// 把工具中心抛出的错误变成提示；用户取消（`.declined`）不算错误，静默结束。
  private static func failure(_ error: Error) -> Outcome {
    if let error = error as? ToolCenterError, error == .declined { return Outcome(succeeded: false) }
    return Outcome(succeeded: false, message: error.localizedDescription, isError: true)
  }

  /// 提示里用的插件名；刚安装的插件可能还没进列表，退回 id。
  private func displayName(_ id: String) -> String {
    tools.pluginSummaries.first { $0.id == id }?.name ?? id
  }

  /// 只接受 JSON 布尔值；数字 0 / 1 不算（与 `applyWebSetting` 的规则一致）。
  private static func strictBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  // MARK: - 推送合并

  /// 工具中心可能在一次扫描里连发多次 changes：合并成下一轮主队列的一次推送。
  private func scheduleSnapshot() {
    guard !snapshotPending else { return }
    snapshotPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.snapshotPending else { return }
      self.snapshotPending = false
      self.pushSnapshot()
    }
  }

  /// 立即推送，并取消已排队的合并推送。动作里的同步调用往往先触发 changes，
  /// 这样同一次变化只推一份快照，网页下一次提交不会因为 revision 又涨了而被判过期。
  private func pushSnapshotNow() {
    snapshotPending = false
    pushSnapshot()
  }

  // MARK: - 原生对话框

  /// 卸载确认，以 sheet 挂在设置窗口上（不用 runModal：模态泵会把排队的刷新拉进当前调用，
  /// 见 docs/developer/engineering-pitfalls.md）。没有窗口时不卸载。
  static func presentUninstallConfirmation(name: String, window: NSWindow?) async -> Bool {
    guard let window else { return false }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("卸载插件「\(name)」？")
    alert.informativeText = L("插件目录会移到废纸篓，插件数据会删除。")
    alert.addButton(withTitle: L("卸载")).hasDestructiveAction = true
    alert.addButton(withTitle: L("取消"))
    let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
    return response == .alertFirstButtonReturn
  }

  /// 只能选一个目录的打开面板，同样以 sheet 呈现。没有窗口或用户取消时返回 nil。
  static func presentFolderPanel(_ purpose: FolderPurpose, window: NSWindow?) async -> URL? {
    guard let window else { return nil }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = L("文件夹根目录里要有 aster-plugin.json。")
    switch purpose {
    case .install:
      panel.title = L("选择要安装的插件文件夹")
      panel.prompt = L("安装")
    case .development:
      panel.title = L("选择插件的开发目录")
      panel.prompt = L("添加")
    }
    return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
      panel.beginSheetModal(for: window) { response in
        continuation.resume(returning: response == .OK ? panel.url?.standardizedFileURL : nil)
      }
    }
  }
}

/// 全局快捷键撞车：`tools.launcherShortcut` 与 `quickTerminal.shortcut` 不能选同一组合。
enum SettingsShortcutConflict: LocalizedError, Equatable {
  /// 工具面板想用的组合已被 Quick Terminal 占用。
  case usedByQuickTerminal
  /// Quick Terminal 想用的组合已被工具面板占用。
  case usedByToolLauncher

  var errorDescription: String? {
    switch self {
    case .usedByQuickTerminal: L("这个组合已被 Quick Terminal 使用，请为工具面板换一个")
    case .usedByToolLauncher: L("这个组合已被工具面板使用，请为 Quick Terminal 换一个")
    }
  }
}
