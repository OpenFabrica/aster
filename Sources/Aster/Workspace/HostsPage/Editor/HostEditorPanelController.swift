// 主机页右侧滑出的编辑面板（类似 Termius 的「Edit host」抽屉）：标题带、可滚动的分区表单、
// 操作区与底部「取消 / 保存」。保存走 `SSHHostEditing.save`（与其它保存入口同一套清理与校验），
// 失败原因显示在底部，不落盘；面板本身不持有主机数据的可写副本。
import AppKit
import AsterCore

/// 编辑面板打开的对象。
enum HostEditorMode: Equatable {
  /// 新建主机，草稿已按搜索词或当前分组预填。
  case new(SSHHostDraft)
  /// 编辑一台已保存主机。
  case edit(UUID)
  /// 编辑「默认」项。
  case defaults
}

/// 面板里「操作」区的动作；由宿主（主机页）执行。
enum HostEditorAction: Equatable {
  case addMachine
  case forgetPassword
  case duplicate
  case delete
  case editSSHConfig
}

/// 编辑面板的宿主：负责关闭面板、保存后的收尾与「操作」区的具体执行。
@MainActor
protocol HostEditorPanelHost: AnyObject {
  /// 用户取消或关闭面板。
  func hostEditorDidClose(_ panel: HostEditorPanelController)
  /// 保存成功；`profile` 是实际写入的配置。
  func hostEditor(_ panel: HostEditorPanelController, didSave profile: SSHHostProfile)
  /// 执行「操作」区的一项动作。
  func hostEditor(_ panel: HostEditorPanelController, perform action: HostEditorAction, hostID: UUID)
  /// 这台主机的 endpoint 是否保存了口令（钥匙串查询，不能占用主线程）。
  func hostEditorHasPassword(hostID: UUID) async -> Bool
}

/// 面板根视图：底色 + 左侧分隔线；Esc 在没有输入框接住时由这里关闭面板。
@MainActor
final class HostEditorPanelView: HostsPageFilledView {
  var onCancel: (() -> Void)?

  override func cancelOperation(_ sender: Any?) { onCancel?() }
  override var acceptsFirstResponder: Bool { true }
}

/// 编辑面板控制器。每次打开都新建一个实例，草稿只活在面板生命周期里。
@MainActor
final class HostEditorPanelController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
  let mode: HostEditorMode
  let directory: SSHHostDirectory
  weak var host: HostEditorPanelHost?
  private(set) var form: HostEditorForm!
  /// 打开时控件里的草稿，用来判断是否有未保存的修改。
  private var baseline: SSHHostDraft?
  private let context: HostEditorContext
  let statusLabel = makeHostEditorHint("")
  private(set) var saveButton: HostEditorButton!
  private(set) var forgetPasswordButton: HostEditorButton?
  private var passwordLookup: Task<Void, Never>?

  /// 按模式与上下文建面板；上下文由宿主从目录与保险库的当前快照生成。
  init(mode: HostEditorMode, context: HostEditorContext, directory: SSHHostDirectory, host: HostEditorPanelHost?) {
    self.mode = mode
    self.context = context
    self.directory = directory
    self.host = host
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  /// 编辑的主机 ID（新建时是新草稿的 ID）。
  var hostID: UUID { context.draft.id }

  /// 控件内容与打开时不同。
  var isDirty: Bool {
    guard let baseline, isViewLoaded else { return false }
    return form.currentDraft() != baseline
  }

  override func loadView() {
    let root = HostEditorPanelView(fillColor: HostsPagePalette.drawer, cornerRadius: 0)
    root.identifier = NSUserInterfaceItemIdentifier("host-editor-panel")
    root.onCancel = { [weak self] in self?.cancel() }
    root.setAccessibilityRole(.group)
    root.setAccessibilityLabel(title)
    view = root
    form = HostEditorForm(context: context, fieldDelegate: self)
    for area in [form.identityFiles, form.knownHostsFiles] { area.textView.delegate = self }
    buildLayout(in: root)
    baseline = form.currentDraft()
    refreshPasswordState()
  }

  /// 面板标题与说明。
  override var title: String? {
    get {
      switch mode {
      case .new: L("新建主机")
      case .edit: L("编辑“\(context.draft.name)”")
      case .defaults: L("默认设置")
      }
    }
    set {}
  }

  private var subtitle: String {
    mode == .defaults ? L("所有主机都继承这里的值。留空表示使用内置默认值。") : L("留空的字段继承「默认」项。")
  }

  /// 把键盘焦点交给第一个输入框。
  func focusFirstField() {
    view.window?.makeFirstResponder(form.initialFirstResponder)
  }

  // MARK: - 布局

  /// 标题带 + 滚动表单 + 底栏，左侧一条分隔线。
  private func buildLayout(in root: NSView) {
    let header = makeHeader()
    let scroll = makeScrollView()
    let footer = makeFooter()
    let edge = HostsPageFilledView(fillColor: AsterTheme.hairline, cornerRadius: 0)
    let topRule = HostsPageFilledView(fillColor: AsterTheme.divider, cornerRadius: 0)
    let bottomRule = HostsPageFilledView(fillColor: AsterTheme.divider, cornerRadius: 0)
    for subview in [header, topRule, scroll, bottomRule, footer, edge] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(subview)
    }
    let inset = HostEditorMetrics.inset
    NSLayoutConstraint.activate([
      edge.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      edge.topAnchor.constraint(equalTo: root.topAnchor),
      edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      edge.widthAnchor.constraint(equalToConstant: 1),

      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      topRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
      topRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
      topRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      topRule.heightAnchor.constraint(equalToConstant: 1),

      scroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),

      bottomRule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
      bottomRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      bottomRule.heightAnchor.constraint(equalToConstant: 1),
      bottomRule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
    ])
  }

  /// 标题、说明与右上角关闭按钮。
  private func makeHeader() -> NSView {
    let titleLabel = makeLabel(title ?? "", size: 15, weight: .semibold, color: AsterTheme.ink)
    titleLabel.identifier = NSUserInterfaceItemIdentifier("host-editor-title")
    let subtitleLabel = makeLabel(subtitle, size: 11.5, color: AsterTheme.secondaryInk)
    let column = NSStackView(views: [titleLabel, subtitleLabel])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 3
    let close = IconHoverButton(symbol: "xmark", accessibilityDescription: L("关闭")) { [weak self] in self?.cancel() }
    close.identifier = NSUserInterfaceItemIdentifier("host-editor-close")
    close.toolTip = L("关闭")
    let header = NSView()
    for subview in [column, close] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      header.addSubview(subview)
    }
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      column.topAnchor.constraint(equalTo: header.topAnchor),
      column.bottomAnchor.constraint(equalTo: header.bottomAnchor),
      column.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
      close.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      close.topAnchor.constraint(equalTo: header.topAnchor, constant: -2),
      close.widthAnchor.constraint(equalToConstant: 26),
      close.heightAnchor.constraint(equalToConstant: 26),
    ])
    return header
  }

  /// 可滚动的分区表单；编辑已有主机时末尾加「操作」区。
  private func makeScrollView() -> NSScrollView {
    let scroll = NSScrollView()
    scroll.identifier = NSUserInterfaceItemIdentifier("host-editor-scroll")
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = document
    var blocks: [NSView] = form.sections
    if case .edit(let id) = mode { blocks.append(makeActionsSection(hostID: id)) }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    for (index, block) in blocks.enumerated() {
      if index > 0 {
        let rule = HostsPageFilledView(fillColor: AsterTheme.divider, cornerRadius: 0)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      }
      stack.addArrangedSubview(block)
      block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    document.addSubview(stack)
    let clip = scroll.contentView
    let inset = HostEditorMetrics.inset
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset - 1),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
    ])
    return scroll
  }

  /// 「操作」区：添加为远程机器、忘记口令（有口令时才显示）、创建副本、编辑 ~/.ssh/config、删除。
  private func makeActionsSection(hostID: UUID) -> NSView {
    let section = HostEditorSectionView(
      title: L("操作"), identifier: "host-editor-section-actions", expanded: true, collapsible: false)
    /// 一个操作按钮。
    func button(_ title: String, _ symbol: String, _ action: HostEditorAction, style: HostEditorButton.Style = .secondary)
      -> HostEditorButton
    {
      let button = HostEditorButton(title: title, symbol: symbol, style: style) { [weak self] in
        guard let self else { return }
        self.host?.hostEditor(self, perform: action, hostID: hostID)
      }
      button.identifier = NSUserInterfaceItemIdentifier("host-editor-action-\(action)")
      section.addRow(button)
      return button
    }
    _ = button(L("添加为远程机器…"), "desktopcomputer", .addMachine)
    let forget = button(L("忘记保存的口令…"), "key", .forgetPassword)
    forget.isHidden = true
    forgetPasswordButton = forget
    _ = button(L("创建副本"), "plus.square.on.square", .duplicate)
    _ = button(L("在 ~/.ssh/config 中编辑"), "doc.text", .editSSHConfig)
    _ = button(L("删除主机…"), "trash", .delete, style: .danger)
    return section
  }

  /// 底栏：错误说明 + 取消 / 保存。
  private func makeFooter() -> NSView {
    statusLabel.identifier = NSUserInterfaceItemIdentifier("host-editor-status")
    statusLabel.textColor = .systemRed
    statusLabel.isHidden = true
    let cancel = HostEditorButton(title: L("取消"), style: .secondary) { [weak self] in self?.cancel() }
    cancel.identifier = NSUserInterfaceItemIdentifier("host-editor-cancel")
    saveButton = HostEditorButton(title: L("保存"), style: .primary) { [weak self] in self?.save() }
    saveButton.identifier = NSUserInterfaceItemIdentifier("host-editor-save")
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let buttons = NSStackView(views: [spacer, cancel, saveButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    let footer = NSStackView(views: [statusLabel, buttons])
    footer.orientation = .vertical
    footer.alignment = .leading
    footer.spacing = 10
    statusLabel.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
    return footer
  }

  // MARK: - 动作

  /// 收集草稿 → 组装 → 按存储规则保存；失败原因显示在底栏，表单保留。
  func save() {
    do {
      let profile = try form.currentDraft().makeProfile()
      let isEdit = if case .edit = mode { true } else { false }
      let saved = try SSHHostEditing.save(profile, in: directory, requireExisting: isEdit)
      showError(nil)
      baseline = form.currentDraft()
      host?.hostEditor(self, didSave: saved)
    } catch {
      showError(SSHHostEditing.describe(error))
    }
  }

  /// 放弃修改并关闭。
  func cancel() {
    host?.hostEditorDidClose(self)
  }

  /// 显示或清除底栏错误。
  func showError(_ message: String?) {
    statusLabel.stringValue = message ?? ""
    statusLabel.isHidden = message == nil
  }

  /// 后台查询口令状态，决定是否显示「忘记保存的口令…」；面板关闭后结果丢弃。
  func refreshPasswordState() {
    guard case .edit(let id) = mode, forgetPasswordButton != nil else { return }
    passwordLookup?.cancel()
    passwordLookup = Task { @MainActor [weak self] in
      guard let host = self?.host else { return }
      let hasPassword = await host.hostEditorHasPassword(hostID: id)
      guard !Task.isCancelled, let button = self?.forgetPasswordButton else { return }
      button.isHidden = !hasPassword
      // 栈视图隐藏子视图时会拆掉它与栈的约束；重新显示后补回「撑满宽度」。
      if hasPassword, let row = button.superview,
        !row.constraints.contains(where: { $0.firstItem === button && $0.firstAttribute == .width })
      {
        button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
      }
    }
  }

  // MARK: - 键盘

  /// 单行输入框：Esc 关闭面板，回车保存。
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      cancel()
      return true
    case #selector(NSResponder.insertNewline(_:)):
      save()
      return true
    default:
      return false
    }
  }

  /// 多行输入框：Esc 关闭面板（默认行为会弹出补全），回车照常换行。
  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    cancel()
    return true
  }
}
