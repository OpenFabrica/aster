// 工具与工作区的衔接：把工具开成 Pane、按 Pane 缓存工具会话、解析来源终端，
// 以及在新标签里运行脚本工具的 `terminal` 输出。
import AppKit
import AsterCore
import Combine

// MARK: - 工具 Pane 的显示名

extension PaneDescriptor {
  /// 工具 Pane 的显示名：`resourcePath` 存的是功能 id（`<pluginID>/<code>`），不是文件路径，
  /// 所以取功能标题；功能已停用或卸载时显示「工具」，不向用户暴露内部 id。非工具 Pane 返回 nil。
  @MainActor var toolDisplayTitle: String? {
    guard kind == .tool else { return nil }
    return resourcePath.flatMap { ToolCenter.shared.entry(id: $0)?.feature.title } ?? L("工具")
  }
}

// MARK: - 打开工具 Pane 与来源终端

extension AppModel {
  /// 活动 Pane 是终端时返回它作为工具的来源；文件、网页、工具等 Pane 返回 nil。
  /// SSH 与远端机器上的终端同样可以预填文字，是否远端由 `toolContext(for:)` 标记。
  func toolTerminalOrigin() -> ToolTerminalOrigin? {
    guard let tab = selectedTab, let session = tab.activeSession else { return nil }
    return ToolTerminalOrigin(session: session, paneID: tab.activePaneID)
  }

  /// 按来源 Pane 组装交给工具的环境。只有本机终端才带工作目录：SSH、远端机器或 OSC 7 指向
  /// 别的主机时，脚本不能拿远端路径当本机目录用，只标记 `isRemote`。
  func toolContext(for origin: ToolTerminalOrigin?) -> ToolContext {
    guard let session = origin?.session else {
      return ToolCenter.shared.makeContext(
        workingDirectory: isLocalMachineActive ? selectedTab?.workingDirectory : nil,
        isRemote: !isLocalMachineActive)
    }
    let isRemote = !isLocalMachineActive || session.nativeSSH != nil
      || session.sshRemoteEndpoint != nil || session.remoteWorkingDirectory != nil
      || !session.currentWorkingDirectoryIsLocal
    return ToolCenter.shared.makeContext(
      workingDirectory: isRemote ? nil : session.resolvedCurrentWorkingDirectory(),
      isRemote: isRemote)
  }

  /// 在当前标签里把工具开成 Pane（`PaneKind.tool`，`resourcePath` 是功能 id）。功能不存在时提示并返回 false。
  @discardableResult
  func openToolPane(
    entryID: String,
    input: ToolInput,
    origin: ToolTerminalOrigin?,
    direction: SplitDirection = .right
  ) -> Bool {
    guard let entry = ToolCenter.shared.entry(id: entryID) else {
      notice = L("找不到这个工具，它可能已被停用或卸载")
      return false
    }
    return openToolPane(entry: entry, input: input, origin: origin, direction: direction)
  }

  /// `openToolPane(entryID:…)` 的主体；测试直接传条目，不依赖工具中心当前的目录。
  @discardableResult
  func openToolPane(
    entry: ToolCatalogEntry,
    input: ToolInput,
    origin: ToolTerminalOrigin?,
    direction: SplitDirection = .right
  ) -> Bool {
    // 远端机器上的标签是服务端结构的投影，本地插一个服务端不认识的 Pane 会让两边结构分叉。
    guard remoteStructureHandler == nil else {
      notice = L("远端机器上的工作区暂不支持工具 Pane")
      return false
    }
    guard let tab = selectedTab else { return false }
    // 会话先按预定的 Pane id 建好再拆分：拆分会触发工作区重建，叶子视图创建时缓存里必须已经
    // 有这份带输入与来源的会话，否则会被当成「没有请求」建一个空输入的会话。
    let paneID = UUID()
    toolPaneSessions.makeSession(
      paneID: paneID, request: ToolLaunchRequest(entry: entry, input: input, origin: origin))
    tab.split(direction: direction, kind: .tool, resourcePath: entry.id, paneID: paneID)
    guard tab.layout.descriptor(forPane: paneID) != nil else {
      toolPaneSessions.discard(paneID: paneID)
      return false
    }
    ToolCenter.shared.recordUse(entryID: entry.id)
    persistWorkspace()
    return true
  }

  /// 工作区叶子视图取工具会话：缓存里有就复用；没有（例如跨窗口拖来的 Pane）时按 Pane 记录的
  /// 功能 id 建一个空输入的会话。功能已经不存在时返回 nil，由视图显示占位。
  func toolPaneSession(for descriptor: PaneDescriptor) -> ToolSessionViewController? {
    toolPaneSessions.session(for: descriptor)
  }

  /// 同标签里离工具 Pane 最近的终端；工具请求没有来源时，预填写到这里。
  func nearestTerminalOrigin(toPane paneID: UUID) -> ToolTerminalOrigin? {
    guard let tab = tabs.first(where: { $0.layout.descriptor(forPane: paneID) != nil }),
      let terminalID = tab.layout.nearestPaneID(
        to: paneID, where: { tab.runtime(for: $0.id)?.terminalSession != nil }),
      let session = tab.runtime(for: terminalID)?.terminalSession
    else { return nil }
    return ToolTerminalOrigin(session: session, paneID: terminalID)
  }

  /// 工具请求关闭自己所在的 Pane。语义与 Shell 主动退出相同：标签只剩这一个 Pane 时关掉整个标签，
  /// 没有可丢失的运行态，所以不弹关闭确认。
  func closeToolPane(paneID: UUID) {
    guard let tab = tabs.first(where: { $0.layout.descriptor(forPane: paneID) != nil }) else { return }
    closePaneAfterShellExit(paneID: paneID, in: tab)
  }

  /// 脚本工具 `output == terminal`：在新本地标签里运行命令。参数与环境变量按 POSIX 单引号转义；
  /// 工作目录不存在时退回主目录。失败（远端窗口、控制字符等）用提示说明原因。
  func runToolCommandInNewTab(
    _ command: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) {
    let line: String
    do {
      line = try ToolShellCommand.encode(command: command, environment: environment)
    } catch {
      notice = error.localizedDescription
      return
    }
    var isDirectory: ObjCBool = false
    let directory = workingDirectory.flatMap { path in
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        ? path : nil
    } ?? FileManager.default.homeDirectoryForCurrentUser.path
    if !runCommandInNewTab(line, workingDirectory: directory) {
      notice = L("当前窗口在远端机器上，请先切回本机再运行工具命令")
    }
  }
}

// MARK: - 命令转义

/// 把脚本工具交来的 argv 与环境变量拼成一行可以输入终端的命令。
enum ToolShellCommand {
  /// 拼命令失败的原因。
  enum EncodingError: Error, Equatable, LocalizedError {
    case emptyCommand
    case invalidEnvironmentName(String)
    case controlCharacters

    var errorDescription: String? {
      switch self {
      case .emptyCommand: L("工具没有给出要运行的命令")
      case .invalidEnvironmentName(let name): L("环境变量名无效：\(name)")
      case .controlCharacters: L("命令包含控制字符，已拒绝在终端里运行")
      }
    }
  }

  /// 环境变量放在 `env` 后面而不是写成 `NAME=value cmd`：后者只有 POSIX Shell 认识，fish 等
  /// 用户 Shell 也要能执行。命令里出现控制字符（Unicode Cc：C0、DEL、C1）整条拒绝——制表符会触发
  /// 补全、ESC 序列会触发行编辑器的按键绑定，单引号挡不住这些在输入阶段就生效的字节。
  /// 零宽连接符等格式字符（Cf）不在此列，emoji 序列里会用到它们。
  static func encode(command: [String], environment: [String: String]) throws -> String {
    guard let executable = command.first, !executable.isEmpty else { throw EncodingError.emptyCommand }
    var parts: [String] = []
    if !environment.isEmpty {
      // `env` 把第一个带 `=` 的参数当成赋值；可执行文件名里有 `=` 时会被误读，直接拒绝。
      guard !executable.contains("=") else { throw EncodingError.invalidEnvironmentName(executable) }
      parts.append("env")
      for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
        guard isEnvironmentName(name) else { throw EncodingError.invalidEnvironmentName(name) }
        parts.append(WorkflowShellCommandEncoder.quote("\(name)=\(value)"))
      }
    }
    parts.append(WorkflowShellCommandEncoder.encode(command))
    let line = parts.joined(separator: " ")
    guard !line.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
      throw EncodingError.controlCharacters
    }
    return line
  }

  /// POSIX 环境变量名：ASCII 字母或下划线开头，只含 ASCII 字母、数字、下划线。
  private static func isEnvironmentName(_ name: String) -> Bool {
    /// ASCII 字母或下划线。
    func isLetter(_ scalar: Unicode.Scalar) -> Bool {
      scalar == "_" || ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }
    guard let first = name.unicodeScalars.first, isLetter(first) else { return false }
    return name.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) }
  }
}

// MARK: - 工具 Pane 会话缓存

/// 工具 Pane 的会话缓存，按 Pane id 保存。工作区每次刷新都会重建叶子视图，同一个 Pane 必须复用
/// 同一个控制器，网页工具才不会重新加载；Pane 从本窗口所有标签里消失（关闭 Pane、关闭标签、
/// 拖去别的窗口）后调用 `teardown()` 释放。
@MainActor
final class ToolPaneSessionCache {
  /// 一个工具 Pane 的会话与宿主。会话对宿主是弱引用，宿主由缓存持有。
  private struct Record {
    let session: ToolSessionViewController
    let host: ToolPaneSessionHost
  }

  private weak var model: AppModel?
  private var records: [UUID: Record] = [:]
  private var tabsSubscription: AnyCancellable?
  private var layoutSubscription: AnyCancellable?
  private var reconcileScheduled = false

  /// 订阅模型的标签列表；标签增减时重新订阅各标签的布局。
  init(model: AppModel) {
    self.model = model
    tabsSubscription = model.$tabs.sink { [weak self] tabs in
      self?.observeLayouts(of: tabs)
      self?.scheduleReconcile()
    }
  }

  /// 模型释放（窗口关闭）时停掉全部工具会话。
  isolated deinit {
    for record in records.values { record.session.teardown() }
  }

  /// 当前缓存着会话的 Pane（测试用）。
  var cachedPaneIDs: Set<UUID> { Set(records.keys) }

  /// 为一个 Pane 建会话并缓存；同一 Pane 已有会话时先释放旧的。
  @discardableResult
  func makeSession(paneID: UUID, request: ToolLaunchRequest) -> ToolSessionViewController {
    discard(paneID: paneID)
    let host = ToolPaneSessionHost(model: model, paneID: paneID)
    let session = ToolCenter.shared.makeSession(for: request, host: host)
    host.session = session
    records[paneID] = Record(session: session, host: host)
    return session
  }

  /// 取 Pane 的会话；缓存里没有就按功能 id 现建一个空输入的会话，功能不存在时返回 nil。
  func session(for descriptor: PaneDescriptor) -> ToolSessionViewController? {
    if let record = records[descriptor.id] { return record.session }
    guard let model, let entryID = descriptor.resourcePath,
      let entry = ToolCenter.shared.entry(id: entryID)
    else { return nil }
    let input = ToolInput(context: model.toolContext(for: nil))
    return makeSession(
      paneID: descriptor.id, request: ToolLaunchRequest(entry: entry, input: input, origin: nil))
  }

  /// 释放一个 Pane 的会话：先 `teardown()` 停掉脚本与 WebView，再把视图摘出视图树。
  func discard(paneID: UUID) {
    guard let record = records.removeValue(forKey: paneID) else { return }
    record.session.teardown()
    record.session.removeFromParent()
    record.session.viewIfLoaded?.removeFromSuperview()
  }

  /// 任何标签的布局变化都可能关掉工具 Pane。订阅每个标签的布局，统一在下一轮主队列核对。
  private func observeLayouts(of tabs: [TerminalTabItem]) {
    layoutSubscription = Publishers.MergeMany(tabs.map { $0.$layout.map { _ in () } })
      .sink { [weak self] in self?.scheduleReconcile() }
  }

  /// 核对放到下一轮主队列：`@Published` 在赋值前发事件；Pane 在两个标签之间搬运时，中间有一刻
  /// 它不在任何标签里，同步核对会把正在搬的会话误拆掉。
  private func scheduleReconcile() {
    guard !reconcileScheduled else { return }
    reconcileScheduled = true
    DispatchQueue.main.async { [weak self] in self?.reconcile() }
  }

  /// 释放已经不在本窗口任何标签里的工具 Pane 会话。
  private func reconcile() {
    reconcileScheduled = false
    guard let model else { return }
    let live = Set(model.tabs.flatMap { tab in
      tab.layout.allPanes.lazy.filter { $0.kind == .tool }.map(\.id)
    })
    for paneID in records.keys where !live.contains(paneID) {
      discard(paneID: paneID)
    }
  }
}

/// 工具 Pane 作为工具会话的容器：关闭即关 Pane；高度由分屏决定；提示走工作区 toast；
/// 预填写来源终端（请求没有来源时写同标签里最近的终端）；命令在新标签运行。
@MainActor
final class ToolPaneSessionHost: ToolSessionHost {
  private weak var model: AppModel?
  let paneID: UUID
  /// 承载的会话；只用来找它所在的窗口。
  weak var session: ToolSessionViewController?

  /// 绑定所属模型与 Pane 身份。
  init(model: AppModel?, paneID: UUID) {
    self.model = model
    self.paneID = paneID
  }

  /// 关闭请求可能发自工具自己的回调栈（网页桥接、脚本结束），延后一轮再拆，避免在它收尾前释放。
  func toolSessionDidRequestClose(_ session: ToolSessionViewController) {
    let paneID = paneID
    DispatchQueue.main.async { [weak model] in model?.closeToolPane(paneID: paneID) }
  }

  /// Pane 的高度由分屏决定，忽略工具的高度请求。
  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat) {}

  /// 工作区只有一种提示（toast），错误与普通提示共用。
  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool) {
    model?.notice = text
  }

  /// 有来源就只写来源（来源已关闭则失败，不改写到别的 Pane）；没有来源才找同标签最近的终端。
  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool {
    guard let model else { return false }
    guard let target = session.request.origin ?? model.nearestTerminalOrigin(toPane: paneID) else {
      model.notice = L("这个标签里没有可以预填的终端 Pane")
      return false
    }
    if let failure = target.insert(text) {
      model.notice = failure
      return false
    }
    return true
  }

  /// 已经在 Pane 里，不需要再开一次。
  func toolSessionOpenInPane(_ session: ToolSessionViewController) {}

  /// 在新标签里运行命令。
  func toolSession(
    _ session: ToolSessionViewController,
    runInTerminal command: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) {
    model?.runToolCommandInNewTab(command, workingDirectory: workingDirectory, environment: environment)
  }

  /// 会话视图所在的窗口；Pane 在后台标签里时为 nil。
  var toolSessionWindow: NSWindow? { session?.viewIfLoaded?.window }
}
