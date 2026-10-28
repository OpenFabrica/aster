// 独立工具窗口：把一个工具会话放进普通的可缩放窗口，是工具面板、工具 Pane 之外的第三种容器。
// 窗口不随失去焦点收起，可以和工作区并排长期开着；同一个工具可以开多个窗口，每个窗口一份独立会话。
import AppKit
import AsterCore

/// 一个独立工具窗口。只经 `open(request:model:)` 创建；窗口关闭时结束会话并从登记表里移除。
@MainActor
final class ToolWindowController: NSWindowController, NSWindowDelegate {
  static let defaultWidth: CGFloat = 720
  /// 窗口里除工具外的固定部分：分隔线 + 底栏。
  private static let chromeHeight: CGFloat = 1 + ToolLauncherViewController.footerHeight

  /// 正开着的工具窗口。窗口不归任何工作区持有，由这里保活到关闭。
  private static var openControllers: [ToolWindowController] = []

  /// 当前开着的工具窗口数（测试与菜单用）。
  static var openWindowCount: Int { openControllers.count }

  private weak var model: AppModel?
  private var session: ToolSessionViewController?
  private let footer = ToolLauncherFooterView()
  private var isClosed = false

  /// 在新窗口里打开工具。`model` 是目标工作区：预填、开成 Pane、在终端运行都作用于它。
  @discardableResult
  static func open(request: ToolLaunchRequest, model: AppModel?) -> ToolWindowController {
    let controller = ToolWindowController(request: request, model: model)
    openControllers.append(controller)
    ToolCenter.shared.recordUse(entryID: request.entry.id)
    controller.present()
    return controller
  }

  /// 搭好窗口与内容；会话在这里建，视图加载时开始运行。
  private init(request: ToolLaunchRequest, model: AppModel?) {
    self.model = model
    let window = ToolStandaloneWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 480),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
    window.title = request.entry.feature.title
    // 随 App 发布的工具不写插件名（与启动器行的规则一致），用户插件在副标题里标出来源。
    if request.entry.source != .builtin { window.subtitle = request.entry.pluginName }
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 360, height: 220)
    window.appearance = (NSApp?.delegate as? AsterAppDelegate)?.preferences.preferredAppearance
    super.init(window: window)
    window.delegate = self
    let session = ToolCenter.shared.makeSession(for: request, host: self)
    self.session = session
    window.contentViewController = ToolWindowContentViewController(session: session, footer: footer)
    footer.hints = [L("⌘↩ 预填到终端")]
    window.onCommandReturn = { [weak self] in
      self?.prefillResult()
      return true
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 定尺寸与位置后显示。同一工具记住上次的窗口位置（只有第一个窗口能占用这个名字）；
  /// 没有记录时按工具希望的高度居中，已有工具窗口时从最后一个错开排列。
  private func present() {
    guard let window, let session else { return }
    let height = min(max(session.preferredHeight, 200), 800) + Self.chromeHeight
    window.setContentSize(NSSize(width: Self.defaultWidth, height: height))
    let name = "AsterToolWindow.\(session.request.entry.id)"
    // 先看有没有存过的位置再占用名字：占用名字时 AppKit 会把当前（尚未摆放的）位置写进偏好。
    let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") != nil
    let ownsName = window.setFrameAutosaveName(name)
    if !(ownsName && hasSavedFrame && window.setFrameUsingName(name)) {
      if let previous = Self.openControllers.dropLast().last?.window, previous.isVisible {
        window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
      } else {
        window.center()
      }
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  // MARK: - 动作

  /// `⌘↩`：把工具的结果预填到终端，并把用户带去那个 Pane。
  private func prefillResult() {
    guard let session else { return }
    guard let text = session.primaryResultText, !text.isEmpty else {
      footer.showNotice(L("没有可以预填的结果"), isError: true)
      return
    }
    guard let origin = terminalTarget(for: session) else { return }
    ToolCenter.shared.recordUse(entryID: session.request.entry.id)
    let model = model
    revealWorkspace(paneID: origin.paneID)
    // 终端成为 first responder 之后再写，粘贴保护等界面才挂在正确的视图上（与工具面板一致）。
    DispatchQueue.main.async { [weak model] in
      if let failure = origin.insert(text) { model?.notice = failure }
    }
  }

  /// 预填的目标：有来源就只认来源（已关闭也不改写到别处）；没有来源时取目标工作区当前的活动终端。
  private func terminalTarget(for session: ToolSessionViewController) -> ToolTerminalOrigin? {
    if let origin = session.request.origin { return origin }
    if let origin = model?.toolTerminalOrigin() { return origin }
    footer.showNotice(L("没有可以预填的终端：请先在工作区里选中一个终端 Pane"), isError: true)
    return nil
  }

  /// 激活工作区窗口；给了 Pane 就切到它所在的标签并聚焦。
  private func revealWorkspace(paneID: UUID?) {
    NSApp.activate()
    model?.onRequestWindowFocus?()
    guard let model, let paneID,
      let tab = model.tabs.first(where: { $0.layout.descriptor(forPane: paneID) != nil })
    else { return }
    model.revealWorkspaceLocation(tabID: tab.id, paneID: paneID)
  }

  // MARK: - NSWindowDelegate

  /// 窗口关闭：结束会话（停脚本、释放 WebView），下一轮再从登记表移除，免得在回调里释放自己。
  func windowWillClose(_ notification: Notification) {
    guard !isClosed else { return }
    isClosed = true
    session?.teardown()
    session = nil
    DispatchQueue.main.async { [self] in
      Self.openControllers.removeAll { $0 === self }
    }
  }
}

// MARK: - ToolSessionHost

extension ToolWindowController: ToolSessionHost {
  /// 工具请求关闭：关窗口。请求可能发自工具自己的回调栈，延后一轮。
  func toolSessionDidRequestClose(_ session: ToolSessionViewController) {
    DispatchQueue.main.async { [weak self] in self?.window?.close() }
  }

  /// 窗口大小由用户决定，忽略工具的高度请求。
  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat) {}

  /// 提示显示在窗口底栏。
  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool) {
    footer.showNotice(text, isError: isError)
  }

  /// 工具桥接的 `terminal.insert` 与工具里的「预填」按钮：只写入，不切换窗口。
  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool {
    guard let origin = terminalTarget(for: session) else { return false }
    if let failure = origin.insert(text) {
      footer.showNotice(failure, isError: true)
      return false
    }
    return true
  }

  /// 改成工作区 Pane：成功后关掉窗口，免得同一个工具开两份。
  func toolSessionOpenInPane(_ session: ToolSessionViewController) {
    guard let model else {
      footer.showNotice(L("没有打开的工作区窗口"), isError: true)
      return
    }
    guard model.openToolPane(entryID: session.request.entry.id, input: session.request.input, origin: session.request.origin)
    else {
      footer.showNotice(model.notice ?? L("无法开成 Pane"), isError: true)
      return
    }
    window?.close()
    revealWorkspace(paneID: nil)
  }

  /// 在目标工作区的新标签里运行命令，然后带用户过去看输出。
  func toolSession(
    _ session: ToolSessionViewController,
    runInTerminal command: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) {
    guard let model else {
      footer.showNotice(L("没有打开的工作区窗口"), isError: true)
      return
    }
    model.runToolCommandInNewTab(command, workingDirectory: workingDirectory, environment: environment)
    revealWorkspace(paneID: nil)
  }

  var toolSessionWindow: NSWindow? { window }
}

// MARK: - 内容

/// 工具窗口的内容：工具界面撑满，下面是分隔线与底栏（按键提示 / 短提示）。
@MainActor
private final class ToolWindowContentViewController: NSViewController {
  private let session: ToolSessionViewController
  private let footer: ToolLauncherFooterView

  init(session: ToolSessionViewController, footer: ToolLauncherFooterView) {
    self.session = session
    self.footer = footer
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 自上而下：工具、一像素分隔线、底栏。
  override func loadView() {
    let root = ToolWindowRootView()
    addChild(session)
    let separator = ToolLauncherSeparatorView()
    for subview in [session.view, separator, footer] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      session.view.topAnchor.constraint(equalTo: root.topAnchor),
      session.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      session.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      separator.topAnchor.constraint(equalTo: session.view.bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
      footer.topAnchor.constraint(equalTo: separator.bottomAnchor),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      footer.heightAnchor.constraint(equalToConstant: ToolLauncherViewController.footerHeight),
    ])
    view = root
  }
}

/// 工具窗口根视图：背景与工具面板同色，原生工具在两处看起来一样。
@MainActor
private final class ToolWindowRootView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// 动态颜色在 updateLayer 里按当前外观解析。
  override func updateLayer() {
    layer?.backgroundColor = AsterTheme.panel.cgColor
  }
}
