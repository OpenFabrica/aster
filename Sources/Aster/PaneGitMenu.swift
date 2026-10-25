// Pane Git 菜单的异步加载、用户确认、输入和可取消进度。
import AppKit
import AsterCore
import Foundation

@MainActor
final class PaneGitMenu {
  struct Prompt: Equatable {
    enum Input: Equatable { case none, text, branches([String]) }
    let title: String
    let message: String
    let accept: String
    let input: Input
  }

  @MainActor
  struct Dialogs {
    var prompt: @MainActor (Prompt, NSWindow?) async -> String?
    var cancelPrompt: @MainActor () -> Void
    var progress: @MainActor (String, NSWindow?, @escaping @MainActor () -> Void) -> (@MainActor () -> Void) = { title, parent, cancel in
      guard let parent, parent.isVisible else { cancel(); return {} }
      let progress = PaneGitProgress(title: title, parent: parent, cancel: cancel)
      return { progress.close() }
    }
    var failure: @MainActor (Error, NSWindow?) -> Void = PaneGitMenu.presentFailure

    init() {
      let coordinator = PaneGitPromptCoordinator()
      prompt = { prompt, parent in await PaneGitMenu.presentPrompt(prompt, parent: parent, coordinator: coordinator) }
      cancelPrompt = { coordinator.cancel() }
    }
  }

  private enum Action { case fetch, pull, push, createBranch, commit, merge, rebase, switchBranch(String) }
  private let directory: String?
  private let isRemote: Bool
  private let service: PaneGitService
  private let window: @MainActor () -> NSWindow?
  private let beforeAction: @MainActor () -> Bool
  private let onDismiss: @MainActor () -> Void
  private let onResult: @MainActor (Result<String, Error>) -> Void
  private let openURL: @MainActor (URL) -> Bool
  private let dialogs: Dialogs
  private(set) var task: Task<Void, Never>?
  private var closeProgress: (@MainActor () -> Void)?

  /// load 在后台取得 Git 快照后返回菜单，宿主可在 hover presenter 准备好后显示。
  /// 菜单项持有动作控制器；宿主也可持有本对象，并在 Pane 销毁时调用 cancel。
  /// beforeAction 是可重复调用的目标存活检查，不能依赖已关闭的 popover，也不要承担
  /// dismiss 副作用；onDismiss 只在动作开始时调用一次。
  init(
    directory: String?, isRemote: Bool,
    service: PaneGitService = PaneGitService(),
    window: @escaping @MainActor () -> NSWindow? = { nil },
    beforeAction: @escaping @MainActor () -> Bool = { true },
    onDismiss: @escaping @MainActor () -> Void = {},
    onResult: @escaping @MainActor (Result<String, Error>) -> Void = { _ in },
    openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
    dialogs: Dialogs = Dialogs()
  ) {
    self.directory = directory
    self.isRemote = isRemote
    self.service = service
    self.window = window
    self.beforeAction = beforeAction
    self.onDismiss = onDismiss
    self.onResult = onResult
    self.openURL = openURL
    self.dialogs = dialogs
  }

  /// 非仓库、远端目录、超时或读取失败抛出错误；不伪造空仓库状态。
  func load() async throws -> NSMenu {
    let context = try await service.context(directory: directory, isRemote: isRemote)
    try validateTarget()
    let menu = NSMenu(title: L("Git"))
    menu.autoenablesItems = false
    let branch = context.branch.isEmpty ? "HEAD" : context.branch
    let summary = NSMenuItem(title: L("\(branch) · \(String(context.changedFiles)) 项改动"), action: nil, keyEquivalent: "")
    summary.isEnabled = false
    menu.addItem(summary)
    add(L("提交…"), action: .commit, to: menu)
    add(L("创建分支…"), action: .createBranch, to: menu)
    menu.addItem(.separator())
    add(L("Push"), action: .push, to: menu)
    add(L("Pull"), action: .pull, to: menu)
    add(L("Fetch"), action: .fetch, to: menu)
    menu.addItem(.separator())
    add(L("合并…"), action: .merge, to: menu)
    add(L("变基…"), action: .rebase, to: menu)
    if context.branches.count > 1 {
      menu.addItem(.separator())
      let heading = NSMenuItem(title: L("切换到"), action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for branch in context.branches {
        let item = add(branch, action: .switchBranch(branch), to: menu)
        item.state = branch == context.branch ? .on : .off
        item.isEnabled = branch != context.branch
      }
    }
    let remotes = context.remotes.compactMap { remote in remote.webURL.map { (remote.name, $0) } }
    if !remotes.isEmpty { menu.addItem(.separator()) }
    for (name, url) in remotes {
      let item = ActionMenuItem(title: "\(name) · \(url.host ?? url.absoluteString)") { [self] in
        guard beforeAction() else { return }
        onDismiss()
        if openURL(url) { onResult(.success(url.absoluteString)) }
        else { report(CocoaError(.fileReadUnknown)) }
      }
      item.toolTip = url.absoluteString
      menu.addItem(item)
    }
    return menu
  }

  func cancel() {
    task?.cancel()
    finishProgress()
    dialogs.cancelPrompt()
  }

  @discardableResult
  private func add(_ title: String, action: Action, to menu: NSMenu) -> NSMenuItem {
    let item = ActionMenuItem(title: title) { [self] in start(action) }
    item.isEnabled = task == nil
    menu.addItem(item)
    return item
  }

  private func start(_ action: Action) {
    guard task == nil, beforeAction() else { return }
    onDismiss()
    task = Task { [self] in
      defer { task = nil }
      do { try await perform(action) }
      catch is CancellationError { }
      catch { report(error) }
    }
  }

  private func perform(_ action: Action) async throws {
    try validateTarget()
    let operation: PaneGitService.Operation
    let progress: String
    switch action {
    case .fetch:
      operation = .fetch
      progress = L("正在获取…")
    case .pull:
      guard await ask(.init(title: L("从远程拉取"), message: L("从远程仓库拉取最新改动？"),
        accept: L("Pull"), input: .none)) != nil else { return }
      operation = .pull
      progress = L("正在拉取…")
    case .push:
      let context = try await preparing(L("正在准备推送…")) {
        try await service.context(directory: directory, isRemote: isRemote)
      }
      let branch = context.branch.isEmpty ? "HEAD" : context.branch
      guard await ask(.init(title: L("推送到远程"), message: L("将“\(branch)”推送到远程仓库？"),
        accept: L("Push"), input: .none)) != nil else { return }
      operation = .push
      progress = L("正在推送…")
    case .createBranch:
      guard let branch = await ask(.init(title: L("创建分支"), message: L("输入新分支的名称。"),
        accept: L("创建"), input: .text)) else { return }
      operation = .createBranch(branch)
      progress = L("正在创建分支…")
    case .commit:
      let preparation = try await preparing(L("正在准备提交…")) {
        try await service.prepareCommit(directory: directory, isRemote: isRemote)
      }
      guard preparation.context.stagedFiles > 0 else { throw PaneGitService.Failure.noStagedChanges }
      guard let message = await ask(.init(title: L("提交"), message: preparation.stagedSummary,
        accept: L("提交"), input: .text)) else { return }
      operation = .commit(message)
      progress = L("正在提交…")
    case .merge, .rebase:
      let context = try await preparing(L("正在读取分支…")) {
        try await service.context(directory: directory, isRemote: isRemote)
      }
      let branches = context.branches.filter { $0 != context.branch }
      let merge = if case .merge = action { true } else { false }
      guard let branch = await ask(.init(title: merge ? L("合并分支") : L("变基到分支"),
        message: merge ? L("选择要合并到当前分支的分支。") : L("选择当前分支变基的目标分支。"),
        accept: merge ? L("合并") : L("变基"), input: .branches(branches))) else { return }
      operation = merge ? .merge(branch) : .rebase(branch)
      progress = merge ? L("正在合并…") : L("正在变基…")
    case .switchBranch(let branch):
      operation = .switchBranch(branch)
      progress = L("正在切换分支…")
    }
    try validateTarget()
    let output = try await preparing(progress) {
      try validateTarget()
      return try await service.perform(operation, directory: directory, isRemote: isRemote)
    }
    try validateTarget()
    onResult(.success(output.text))
  }

  private func ask(_ prompt: Prompt) async -> String? {
    guard !Task.isCancelled, beforeAction() else { return nil }
    let value = await dialogs.prompt(prompt, window())
    guard !Task.isCancelled, beforeAction() else { return nil }
    return value
  }

  private func preparing<T: Sendable>(_ title: String, body: @MainActor () async throws -> T) async throws -> T {
    try validateTarget()
    closeProgress = dialogs.progress(title, window()) { [weak self] in self?.cancel() }
    defer { finishProgress() }
    try validateTarget()
    let value = try await body()
    try validateTarget()
    return value
  }

  private func validateTarget() throws {
    try Task.checkCancellation()
    guard beforeAction() else { throw CancellationError() }
  }

  private func finishProgress() {
    let close = closeProgress
    closeProgress = nil
    close?()
  }

  private func report(_ error: Error) {
    guard !Task.isCancelled, beforeAction() else { return }
    dialogs.failure(error, window())
    onResult(.failure(error))
  }

  private static func presentPrompt(_ prompt: Prompt, parent: NSWindow?, coordinator: PaneGitPromptCoordinator) async -> String? {
    guard let parent, parent.isVisible, !Task.isCancelled else { return nil }
    let alert = NSAlert()
    alert.messageText = prompt.title
    alert.informativeText = prompt.message
    let accept = alert.addButton(withTitle: prompt.accept)
    alert.addButton(withTitle: L("取消"))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
    let branches = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28), pullsDown: false)
    switch prompt.input {
    case .none: break
    case .text:
      alert.accessoryView = field
      alert.window.initialFirstResponder = field
    case .branches(let names):
      branches.addItems(withTitles: names)
      accept.isEnabled = !names.isEmpty
      alert.accessoryView = branches
    }
    let response = await coordinator.present(alert, parent: parent)
    guard response == .alertFirstButtonReturn else { return nil }
    switch prompt.input {
    case .none: return ""
    case .text: return field.stringValue
    case .branches: return branches.titleOfSelectedItem
    }
  }

  private static func presentFailure(_ error: Error, parent: NSWindow?) {
    guard let parent, parent.isVisible else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("Git")
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: L("确定"))
    alert.beginSheetModal(for: parent)
  }
}

/// 每套live Dialogs独占一个sheet；取消、owner关闭及正常按钮响应只结束一次continuation。
@MainActor
private final class PaneGitPromptCoordinator {
  private var active: PaneGitPromptSession?

  func present(_ alert: NSAlert, parent: NSWindow) async -> NSApplication.ModalResponse {
    cancel()
    let session = PaneGitPromptSession(alert: alert, parent: parent)
    active = session
    defer { if active === session { active = nil } }
    return await session.run()
  }

  func cancel() { active?.cancel(); active = nil }
}

@MainActor
private final class PaneGitPromptSession: NSObject {
  private let alert: NSAlert
  private weak var parent: NSWindow?
  private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
  private var finished = false

  init(alert: NSAlert, parent: NSWindow) {
    self.alert = alert
    self.parent = parent
    super.init()
  }

  func run() async -> NSApplication.ModalResponse {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !finished, !Task.isCancelled, let parent, parent.isVisible else {
          continuation.resume(returning: .cancel)
          return
        }
        self.continuation = continuation
        NotificationCenter.default.addObserver(self, selector: #selector(ownerClosed(_:)),
          name: NSWindow.willCloseNotification, object: parent)
        alert.beginSheetModal(for: parent) { [weak self] response in
          Task { @MainActor [weak self] in self?.finish(response) }
        }
      }
    } onCancel: {
      Task { @MainActor [self] in self.cancel() }
    }
  }

  func cancel() { finish(.cancel) }
  @objc private func ownerClosed(_ notification: Notification) { cancel() }

  private func finish(_ response: NSApplication.ModalResponse) {
    guard !finished else { return }
    finished = true
    NotificationCenter.default.removeObserver(self)
    let pending = continuation
    continuation = nil
    if let owner = alert.window.sheetParent { owner.endSheet(alert.window, returnCode: response) }
    alert.window.orderOut(nil)
    pending?.resume(returning: response)
  }
}

@MainActor
private final class PaneGitProgress: NSObject {
  private let panel: NSPanel
  private let cancellation: @MainActor () -> Void
  private var closed = false

  init(title: String, parent: NSWindow, cancel: @escaping @MainActor () -> Void) {
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
      styleMask: [.titled], backing: .buffered, defer: false)
    cancellation = cancel
    super.init()
    panel.title = L("Git")
    panel.isReleasedWhenClosed = false
    let indicator = NSProgressIndicator()
    indicator.style = .spinning
    indicator.startAnimation(nil)
    let label = NSTextField(labelWithString: title)
    let row = NSStackView(views: [indicator, label])
    row.spacing = 10
    let button = NSButton(title: L("取消"), target: self, action: #selector(PaneGitProgress.cancel))
    let stack = NSStackView(views: [row, button])
    stack.orientation = .vertical
    stack.alignment = .trailing
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    if let content = panel.contentView {
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      ])
    }
    NotificationCenter.default.addObserver(self, selector: #selector(PaneGitProgress.ownerClosed(_:)),
      name: NSWindow.willCloseNotification, object: parent)
    parent.beginSheet(panel)
  }

  func close() {
    guard !closed else { return }
    closed = true
    NotificationCenter.default.removeObserver(self)
    if let parent = panel.sheetParent { parent.endSheet(panel) }
    panel.orderOut(nil)
  }

  @objc private func cancel() { cancellation(); close() }
  @objc private func ownerClosed(_ notification: Notification) { cancel() }
}
