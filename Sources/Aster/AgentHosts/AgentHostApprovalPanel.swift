// 批准面板：非模态浮动 NSPanel，显示哪个 agent、要连哪台主机、为什么、要执行什么。
// 默认按钮是「拒绝」：回车只会拒绝，绝不会批准；关闭面板也按拒绝处理。
// 面板出现或内容变化后，批准按钮先禁用一小段时间：避免用户正要点别处时面板恰好弹出 / 换了内容，
// 一次误点就批准了没看过的命令。「拒绝」始终可点。
import AppKit
import AsterCore

/// 一个批准请求的面板。
@MainActor
final class AgentHostApprovalPanel: NSObject, AgentHostApprovalPanelHandling, NSWindowDelegate {
  /// 面板出现或内容变化后，批准按钮禁用的时长。
  static let approvalArmDelay: Duration = .seconds(1)

  private let panel: NSPanel
  private let onAnswer: @MainActor (AgentHostApprovalAnswer) -> Void
  private let agentLabel = NSTextField(wrappingLabelWithString: "")
  private let hostLabel = NSTextField(wrappingLabelWithString: "")
  private let reasonLabel = NSTextField(wrappingLabelWithString: "")
  private let pendingLabel = NSTextField(labelWithString: "")
  private let commandView = NSTextView()
  private var answered = false
  /// 三个批准按钮（不含拒绝）。
  private var approveButtons: [NSButton] = []
  /// 每次重新禁用都加一；旧的启用任务发现代数变了就作废。
  private var armGeneration = 0

  /// 建面板并立即显示（不抢键盘焦点之外的东西：用户正在别处打字时不会被打断）。
  init(request: AgentHostApprovalRequest, onAnswer: @escaping @MainActor (AgentHostApprovalAnswer) -> Void) {
    self.onAnswer = onAnswer
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.title = L("Agent 请求访问主机")
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 420, height: 300)
    panel.delegate = self
    panel.contentView = makeContent()
    update(request, pendingCount: 1)
    panel.center()
    panel.orderFrontRegardless()
  }

  /// 批准按钮是否可点（测试用）。
  var approveButtonsEnabled: Bool { approveButtons.allSatisfy(\.isEnabled) }

  /// 刷新显示内容（相同请求合并到达时），并重新延迟启用批准按钮。
  func update(_ request: AgentHostApprovalRequest, pendingCount: Int) {
    var agent = L("Agent：\(request.caller.displayName)")
    if let pane = request.caller.pane { agent += L("（Pane \(pane)）") }
    if let client = request.caller.client, client != request.caller.displayName { agent += " · \(client)" }
    agentLabel.stringValue = agent
    hostLabel.stringValue = L("主机：\(request.hostName)（\(request.target)）")
    let reason = request.reason.flatMap { $0.isEmpty ? nil : $0 } ?? L("（未说明）")
    reasonLabel.stringValue = L("理由：\(reason)")
    commandView.string = request.command ?? L("（只打开 SSH 终端，不执行命令）")
    pendingLabel.stringValue = pendingCount > 1 ? L("这条命令有 \(pendingCount) 个相同的请求在等待；「允许一次」只放行其中一个。") : ""
    pendingLabel.isHidden = pendingCount <= 1
    armApproveButtons()
  }

  /// 先禁用批准按钮，到时再启用；期间再次调用会重新计时。
  private func armApproveButtons() {
    armGeneration += 1
    let generation = armGeneration
    for button in approveButtons { button.isEnabled = false }
    Task { @MainActor [weak self] in
      do { try await Task.sleep(for: Self.approvalArmDelay) } catch { return }
      guard let self, self.armGeneration == generation, !self.answered else { return }
      for button in self.approveButtons { button.isEnabled = true }
    }
  }

  func close() {
    answered = true
    panel.delegate = nil
    panel.orderOut(nil)
    panel.close()
  }

  /// 标题栏关闭按钮：按拒绝处理，避免「关掉了但其实还挂着」。
  func windowWillClose(_ notification: Notification) {
    guard !answered else { return }
    answered = true
    onAnswer(.deny)
  }

  // MARK: - 布局

  private func makeContent() -> NSView {
    let title = NSTextField(labelWithString: L("允许这个 agent 在下面的主机上执行命令吗？"))
    title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
    for label in [agentLabel, hostLabel, reasonLabel] { label.isSelectable = true }
    pendingLabel.textColor = .secondaryLabelColor

    commandView.isEditable = false
    commandView.isSelectable = true
    commandView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
    commandView.textContainerInset = NSSize(width: 6, height: 6)
    commandView.isVerticallyResizable = true
    commandView.autoresizingMask = [.width]
    commandView.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView()
    scroll.documentView = commandView
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

    let note = NSTextField(wrappingLabelWithString: L("命令会在你看得见的终端里执行，你可以随时接管或中断。"))
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    let deny = button(L("拒绝"), .deny)
    // 回车 = 拒绝：误按回车绝不能变成批准。
    deny.keyEquivalent = "\r"
    approveButtons = [
      button(L("允许一次"), .allowOnce), button(L("本会话允许"), .allowSession),
      button(L("一直允许此主机"), .allowAlways),
    ]
    let buttons = NSStackView(views: [deny, NSView()] + approveButtons)
    buttons.orientation = .horizontal
    buttons.spacing = 8

    let stack = NSStackView(views: [title, agentLabel, hostLabel, reasonLabel, scroll, pendingLabel, note, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
    for view in [scroll, buttons, agentLabel, hostLabel, reasonLabel, note] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
    }
    return stack
  }

  private func button(_ title: String, _ answer: AgentHostApprovalAnswer) -> NSButton {
    let button = AgentHostAnswerButton(title: title, target: self, action: #selector(answerClicked(_:)))
    button.answer = answer
    button.bezelStyle = .rounded
    return button
  }

  /// 按钮回调；禁用期内的批准点击（理论上不会送达）再挡一次。
  @objc private func answerClicked(_ sender: NSButton) {
    guard !answered, sender.isEnabled, let answer = (sender as? AgentHostAnswerButton)?.answer else { return }
    answered = true
    onAnswer(answer)
  }
}

/// 带回答值的按钮。
private final class AgentHostAnswerButton: NSButton {
  var answer: AgentHostApprovalAnswer?
}
