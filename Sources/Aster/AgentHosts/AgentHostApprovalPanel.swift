// 批准面板：非模态浮动 NSPanel，显示哪个 agent、要连哪台主机、为什么、要执行什么。
// 默认按钮是「拒绝」：回车只会拒绝，绝不会批准；关闭面板也按拒绝处理。
import AppKit
import AsterCore

/// 一个批准请求的面板。
@MainActor
final class AgentHostApprovalPanel: NSObject, AgentHostApprovalPanelHandling, NSWindowDelegate {
  private let panel: NSPanel
  private let onAnswer: @MainActor (AgentHostApprovalAnswer) -> Void
  private let agentLabel = NSTextField(wrappingLabelWithString: "")
  private let hostLabel = NSTextField(wrappingLabelWithString: "")
  private let reasonLabel = NSTextField(wrappingLabelWithString: "")
  private let pendingLabel = NSTextField(labelWithString: "")
  private let commandView = NSTextView()
  private var answered = false

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

  /// 刷新显示内容（合并的新请求到达时）。
  func update(_ request: AgentHostApprovalRequest, pendingCount: Int) {
    var agent = L("Agent：\(request.caller.displayName)")
    if let pane = request.caller.pane { agent += L("（Pane \(pane)）") }
    if let client = request.caller.client, client != request.caller.displayName { agent += " · \(client)" }
    agentLabel.stringValue = agent
    hostLabel.stringValue = L("主机：\(request.hostName)（\(request.target)）")
    let reason = request.reason.flatMap { $0.isEmpty ? nil : $0 } ?? L("（未说明）")
    reasonLabel.stringValue = L("理由：\(reason)")
    commandView.string = request.command ?? L("（只打开 SSH 终端，不执行命令）")
    pendingLabel.stringValue = pendingCount > 1 ? L("同一会话共有 \(pendingCount) 条请求在等待；批准对这台主机生效。") : ""
    pendingLabel.isHidden = pendingCount <= 1
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

    let note = NSTextField(wrappingLabelWithString: L("命令会在浮动终端里执行，你可以随时接手、中断或暂停 agent。"))
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    let deny = button(L("拒绝"), .deny)
    // 回车 = 拒绝：误按回车绝不能变成批准。
    deny.keyEquivalent = "\r"
    let buttons = NSStackView(views: [
      deny, NSView(), button(L("允许一次"), .allowOnce), button(L("本会话允许"), .allowSession),
      button(L("一直允许此主机"), .allowAlways),
    ])
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

  @objc private func answerClicked(_ sender: NSButton) {
    guard !answered, let answer = (sender as? AgentHostAnswerButton)?.answer else { return }
    answered = true
    onAnswer(answer)
  }
}

/// 带回答值的按钮。
private final class AgentHostAnswerButton: NSButton {
  var answer: AgentHostApprovalAnswer?
}
