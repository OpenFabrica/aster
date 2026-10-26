import AppKit
import AsterCore
import Combine

/// 内容区顶条（`makeWorkspaceHeader` 的 `background`）：承载路径胶囊与安全输入指示器。
/// 隐藏原生标题栏后（`titleVisibility = .hidden`）这条 28pt 区域失去了系统自带的
/// 「双击标题栏放大/还原窗口」手势，这里在空白处（路径胶囊、指示器等子视图仍优先
/// 吃掉命中）手动补回，双击调用 `NSWindow.performZoom` 与「显示」菜单的「缩放」项等效。
@MainActor
final class WorkspaceTitleBarBackgroundView: NSView {
  override func mouseDown(with event: NSEvent) {
    guard event.clickCount == 2 else {
      super.mouseDown(with: event)
      return
    }
    window?.performZoom(nil)
  }
}

/// 工作区标题按钮：终端显示当前目录，文件 Pane 显示资源标题。
@MainActor
final class WorkspaceTitleButton: NSButton {
  var programTitle: String {
    didSet { updatePresentation() }
  }
  var workingDirectory: String {
    didSet { updatePresentation() }
  }
  var resourceTitle: String? {
    didSet { updatePresentation() }
  }
  /// 活动 Pane 的 Agent 会话标题。有值时胶囊显示它（工作目录退到 toolTip），
  /// 没有 Agent 或标题尚未产生时保持原有的缩写目录胶囊。
  var agentSessionTitle: String? {
    didSet {
      guard agentSessionTitle != oldValue else { return }
      updatePresentation()
    }
  }
  /// 活动 Pane 正在运行的 Agent；对齐 Otty，会话标题前缀该 Agent 的图标。
  var agentProvider: AgentProvider? {
    didSet {
      guard agentProvider != oldValue else { return }
      updatePresentation()
    }
  }

  private let foregroundColor: NSColor
  /// Otty 的 `[titlebar].background` 只涂目录胶囊，胶囊外的整条标题区继承 Window。
  /// 未显式声明该 token 的主题保持透明，不能拿派生终端色造出一块白色药丸。
  private let backgroundColor: NSColor?
  private let handler: (WorkspaceTitleButton) -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false
  private var isPopoverPresented = false

  /// 构建标题栏路径胶囊；`handler` 在点击时弹出工作区动作弹层。
  init(
    programTitle: String,
    workingDirectory: String,
    foregroundColor: NSColor,
    backgroundColor: NSColor?,
    handler: @escaping (WorkspaceTitleButton) -> Void
  ) {
    self.programTitle = programTitle
    self.workingDirectory = workingDirectory
    self.foregroundColor = foregroundColor
    self.backgroundColor = backgroundColor
    self.handler = handler
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .accessoryBarAction
    alignment = .center
    font = NSFont.interface(ofSize: 11.5, weight: .regular)
    lineBreakMode = .byTruncatingMiddle
    contentTintColor = foregroundColor
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = NSColor.clear.cgColor
    target = self
    action = #selector(invoke)
    updatePresentation()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
    updatePresentation()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    updatePresentation()
  }

  func setPopoverPresented(_ presented: Bool) {
    isPopoverPresented = presented
    updatePresentation()
  }

  private func updatePresentation() {
    if let resourceTitle {
      title = "\(resourceTitle) ⋯"
      toolTip = workingDirectory
      image = nil
      imagePosition = .noImage
    } else if let agentSessionTitle {
      title = "\(agentSessionTitle) ⋯"
      // 会话标题占据胶囊时，目录定位信息仍要可达：toolTip 保留完整路径。
      toolTip = workingDirectory
      // 会话标题前放 Agent 图标（与侧栏行同一套图标集），图标集缺图时不放；
      // 标题本身已带 ✳/◐ 等 spinner 前缀时也不放，避免并排两个图标。
      image = AsterControlTitleNormalizer.hasSpinnerPrefix(agentSessionTitle)
        ? nil
        : agentProvider.flatMap { TabIconArtwork.image(named: TabRowButton.agentIconName($0)) }
      imagePosition = image == nil ? .noImage : .imageLeading
    } else {
      title = "\((workingDirectory as NSString).abbreviatingWithTildeInPath) ⋯"
      toolTip = workingDirectory
      image = nil
      imagePosition = .noImage
    }
    // 路径始终使用 titlebar.foreground；悬停只能为未显式设置胶囊背景的主题补充
    // 轻量反馈，不能覆盖 April / Ayu / Pink 等主题声明的 titlebar.background。
    contentTintColor = foregroundColor
    if let backgroundColor {
      layer?.backgroundColor = backgroundColor.cgColor
    } else if isHovered || isPopoverPresented {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.075).cgColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  @objc private func invoke() { handler(self) }
}

/// `NSSegmentedControl` 保留原生键盘/辅助功能和 target-action，但按参考界面重绘为
/// 灰色轨道 + 白色选中胶囊。系统 `.capsule` 的选中段仍是深灰，视觉层级正好相反。
@MainActor
private final class WorkspaceTitleModeControl: NSSegmentedControl {
  /// 自绘灰色轨道、白色选中胶囊与各段文字。
  override func draw(_ dirtyRect: NSRect) {
    let track = bounds.insetBy(dx: 0, dy: 1)
    let radius = track.height / 2
    AsterTheme.ink.withAlphaComponent(0.065).setFill()
    NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

    let segmentWidth = track.width / CGFloat(max(1, segmentCount))
    if selectedSegment >= 0 {
      let selected = NSRect(
        x: track.minX + CGFloat(selectedSegment) * segmentWidth + 2,
        y: track.minY + 2,
        width: segmentWidth - 4,
        height: track.height - 4
      )
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowBlurRadius = 2
      shadow.shadowOffset = NSSize(width: 0, height: -1)
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
      shadow.set()
      NSColor.controlBackgroundColor.setFill()
      NSBezierPath(
        roundedRect: selected,
        xRadius: selected.height / 2,
        yRadius: selected.height / 2
      ).fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    for index in 0..<segmentCount {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.interface(
          ofSize: 11.5, weight: index == selectedSegment ? .semibold : .regular),
        .foregroundColor: index == selectedSegment ? AsterTheme.ink : AsterTheme.secondaryInk,
        .paragraphStyle: paragraph,
      ]
      let label = label(forSegment: index) ?? ""
      let textSize = label.size(withAttributes: attributes)
      let rect = NSRect(
        x: track.minX + CGFloat(index) * segmentWidth,
        y: track.midY - textSize.height / 2,
        width: segmentWidth,
        height: textSize.height
      )
      label.draw(in: rect, withAttributes: attributes)
    }
  }
}

/// Otty 式标题工作区弹层。非模态级联保留 hover 与键盘交互；
/// Git 使用独立异步流程，其余操作绑定打开时的标签和 Pane。
@MainActor
final class WorkspaceTitlePopoverViewController: NSViewController, NSTextFieldDelegate {
  let model: AppModel
  let preferences: AppPreferences
  weak var tab: TerminalTabItem?
  let paneID: UUID
  let menuPresenter = PaneMenuPresenter()
  var onDismiss: (() -> Void)?
  weak var ownerWindow: NSWindow?
  weak var toggleAnchor: NSView?
  var isDismissing = false
  private var isChangingMode = false
  private var editingMode: TabTitleEditorState.Mode
  private var dismissalMonitor: PaneMenuDismissalMonitor?
  private var navigationRows: [WorkspaceTitleRowButton] = []
  var pasteboard = NSPasteboard.general
  var gitLoadTask: Task<Void, Never>?
  var gitMenuController: PaneGitMenu?
  private var contextSubscriptions: Set<AnyCancellable> = []
  private weak var modeControl: NSSegmentedControl?
  private weak var titleField: NSTextField?

  /// 弹层尺寸（默认档 280×492）。行高与行宽都随界面字号放大，弹层整体同比放大；
  /// 1.5 倍约 420×738，常见屏幕放得下，所以不设上限，否则底部的行会被裁掉。
  static let preferredSize = NSSize(
    width: InterfaceScale.length(280), height: InterfaceScale.length(492))
  /// 命名、目录和分隔线保留 14pt 外边距；动作行扩展到距弹层边框 7pt。
  private static let rowWidth = preferredSize.width - 28
  private static let actionRowWidth = preferredSize.width - 14

  /// 绑定当前标签；弹层尺寸由 `preferredSize` 决定。
  init(model: AppModel, preferences: AppPreferences, tab: TerminalTabItem) {
    self.model = model
    self.preferences = preferences
    self.tab = tab
    paneID = tab.activePaneID
    editingMode = tab.titleEditorState.mode
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = Self.preferredSize
    tab.activePaneChanged.sink { [weak self] _ in self?.dismiss() }
      .store(in: &contextSubscriptions)
    model.$selectedTabID.dropFirst().sink { [weak self] _ in self?.dismiss() }
      .store(in: &contextSubscriptions)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard let window = view.window, !isDismissing else { return }
    dismissalMonitor = PaneMenuDismissalMonitor(window: window, menus: menuPresenter,
      toggleAnchor: toggleAnchor) { [weak self] in
      self?.dismiss()
    }
  }

  func stopDismissalMonitoring() { dismissalMonitor = nil }

  func focusNameField() { view.window?.makeFirstResponder(titleField) }

  /// 自上而下排列命名区、工作目录与各组动作行。
  override func loadView() {
    let root = NSView(frame: NSRect(origin: .zero, size: Self.preferredSize))
    root.identifier = NSUserInterfaceItemIdentifier("workspace-title-popover")
    root.wantsLayer = true
    view = root

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .centerX
    content.spacing = 1
    root.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 7),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -7),
      content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
      content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
    ])

    content.addArrangedSubview(makeNamingHeader())
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeWorkingDirectoryBlock())
    content.addArrangedSubview(makeRow(
      L("复制路径"), identifier: "workspace-title-copy-path"
    ) { [weak self] _ in self?.copyPath() })
    content.addArrangedSubview(makeRow(
      L("在 Finder 中显示"), identifier: "workspace-title-reveal-finder"
    ) { [weak self] _ in self?.revealInFinder() })
    content.addArrangedSubview(makeRow(
      L("打开方式"), identifier: "workspace-title-open-in", showsSubmenu: true
    ) { [weak self] sender in self?.showOpenInMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      "Git", identifier: "workspace-title-git", showsSubmenu: true
    ) { [weak self] sender in self?.showGitMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      L("通知与权限"), identifier: "workspace-title-notifications",
      trailingSymbols: privilegeSymbols, showsSubmenu: true
    ) { [weak self] sender in self?.showPrivilegesMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      L("分屏"), identifier: "workspace-title-split", showsSubmenu: true
    ) { [weak self] sender in self?.showSplitMenu(from: sender) })
    content.addArrangedSubview(makeRow(
      L("关于此 Pane"), identifier: "workspace-title-about", showsSubmenu: true
    ) { [weak self] sender in self?.showAboutMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      L("查找"), identifier: "workspace-title-find", shortcut: "⌘F"
    ) { [weak self] _ in self?.performNavigation { $0.presentFind() } })
    content.addArrangedSubview(makeRow(
      L("在所有标签中查找"), identifier: "workspace-title-global-find", shortcut: "⌘⇧F"
    ) { [weak self] _ in self?.performNavigation { $0.toggleGlobalFind() } })
    content.addArrangedSubview(makeRow(
      L("跳转到"), identifier: "workspace-title-jump", shortcut: "⌘J"
    ) { [weak self] _ in self?.performNavigation { $0.toggleOpenQuickly() } })
    content.addArrangedSubview(makeRow(
      L("命令面板"), identifier: "workspace-title-palette", shortcut: "⌘⇧P"
    ) { [weak self] _ in self?.performNavigation { $0.togglePalette() } })
  }

  /// 命名区：名称/前缀切换、恢复自动标题按钮与输入框。
  private func makeNamingHeader() -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: InterfaceScale.length(76)).isActive = true

    let segmented = WorkspaceTitleModeControl(
      labels: [L("名称"), L("前缀")], trackingMode: .selectOne,
      target: self, action: #selector(modeChanged(_:)))
    segmented.selectedSegment = selectedMode
    segmented.segmentStyle = .capsule
    segmented.translatesAutoresizingMaskIntoConstraints = false
    modeControl = segmented

    let reset = IconHoverButton(symbol: "arrow.uturn.backward", accessibilityDescription: L("恢复自动标题")) {
      [weak self] in self?.resetName()
    }
    reset.identifier = NSUserInterfaceItemIdentifier("workspace-title-reset-name")
    reset.translatesAutoresizingMaskIntoConstraints = false

    let field = NSTextField(string: currentOverrideText)
    field.identifier = NSUserInterfaceItemIdentifier("workspace-title-name-field")
    field.placeholderString = selectedMode == 0 ? L("标签名称") : L("标签前缀")
    field.font = NSFont.interface(ofSize: 13)
    field.isBezeled = false
    field.drawsBackground = true
    field.backgroundColor = .textBackgroundColor
    field.wantsLayer = true
    field.layer?.cornerRadius = 6
    field.layer?.cornerCurve = .continuous
    field.layer?.borderWidth = 1
    field.layer?.borderColor = NSColor.separatorColor.cgColor
    field.setAccessibilityLabel(L("标签名称或前缀"))
    field.delegate = self
    field.target = self
    field.action = #selector(commitName(_:))
    field.translatesAutoresizingMaskIntoConstraints = false
    titleField = field

    host.addSubview(segmented)
    host.addSubview(reset)
    host.addSubview(field)
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      segmented.topAnchor.constraint(equalTo: host.topAnchor),
      segmented.widthAnchor.constraint(equalToConstant: InterfaceScale.length(142)),
      // 分段控件的固有高度固定 24pt、不随字体变；显式给出缩放后的高度，自绘文字才不被裁。
      segmented.heightAnchor.constraint(equalToConstant: InterfaceScale.length(24)),
      reset.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      reset.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
      reset.widthAnchor.constraint(equalToConstant: InterfaceScale.length(28)),
      reset.heightAnchor.constraint(equalToConstant: InterfaceScale.length(28)),
      field.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      field.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      field.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 9),
      field.heightAnchor.constraint(equalToConstant: InterfaceScale.length(32)),
      host.widthAnchor.constraint(equalToConstant: Self.rowWidth),
    ])
    return host
  }

  /// 工作目录区：小标题 + 文件夹图标与缩写路径。
  private func makeWorkingDirectoryBlock() -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: InterfaceScale.length(54)).isActive = true
    let heading = makeLabel(L("工作目录"), size: 10.5, weight: .semibold,
      color: AsterTheme.tertiaryInk)
    let path = makeLabel(displayDirectory, size: 12.5, color: AsterTheme.secondaryInk)
    path.toolTip = directory
    let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill",
      accessibilityDescription: L("工作目录")) ?? NSImage())
    icon.symbolConfiguration = .init(pointSize: InterfaceScale.font(13), weight: .regular)
    icon.contentTintColor = AsterTheme.tertiaryInk
    for item in [heading, icon, path] {
      host.addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
      heading.topAnchor.constraint(equalTo: host.topAnchor, constant: 5),
      icon.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
      icon.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
      icon.widthAnchor.constraint(equalToConstant: InterfaceScale.length(15)),
      icon.heightAnchor.constraint(equalToConstant: InterfaceScale.length(15)),
      path.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      path.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      path.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor),
      host.widthAnchor.constraint(equalToConstant: Self.rowWidth),
    ])
    return host
  }

  /// 生成一条固定宽高的动作行。
  private func makeRow(
    _ title: String,
    symbol: String? = nil,
    identifier: String,
    shortcut: String? = nil,
    trailingSymbols: [String] = [],
    showsSubmenu: Bool = false,
    handler: @escaping (WorkspaceTitleRowButton) -> Void
  ) -> NSView {
    let button = WorkspaceTitleRowButton(
      title: title, symbol: symbol, shortcut: shortcut, trailingSymbols: trailingSymbols,
      showsSubmenu: showsSubmenu,
      handler: handler)
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    navigationRows.append(button)
    button.onKey = { [weak self, weak button] event in
      guard let self, let button else { return false }
      if self.menuPresenter.handleKey(event) { return true }
      if event.keyCode == 53 { self.dismiss(); return true }
      guard [48, 125, 126].contains(event.keyCode),
        let index = self.navigationRows.firstIndex(where: { $0 === button }) else { return false }
      let backwards = event.keyCode == 126
        || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
      let indices = backwards ? Array(self.navigationRows.indices.prefix(index).reversed())
        : Array(self.navigationRows.indices.dropFirst(index + 1))
      let next = indices.first { self.navigationRows[$0].isEnabled }
      self.menuPresenter.close()
      let responder: NSResponder? = next.map { self.navigationRows[$0] as NSResponder } ?? self.titleField
      self.view.window?.makeFirstResponder(responder)
      return true
    }
    button.onHover = { [weak self] row in
      if showsSubmenu { handler(row) } else { self?.menuPresenter.close() }
    }
    if ["workspace-title-reveal-finder", "workspace-title-open-in"].contains(identifier) {
      button.isEnabled = localDirectoryIsAvailable
    }
    if ["workspace-title-git", "workspace-title-notifications"].contains(identifier) {
      button.isEnabled = session != nil
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.actionRowWidth),
      button.heightAnchor.constraint(equalToConstant: InterfaceScale.length(28)),
    ])
    return button
  }

  /// 动作分组之间的 1pt 分隔线。
  private func makeDivider() -> NSView {
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = AsterTheme.hairline.cgColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      divider.widthAnchor.constraint(equalToConstant: Self.rowWidth),
      divider.heightAnchor.constraint(equalToConstant: 1),
    ])
    return divider
  }

  private var selectedMode: Int { tab?.titleEditorState.mode == .prefix ? 1 : 0 }

  private var currentOverrideText: String {
    tab?.titleEditorState.text(for: selectedMode == 1 ? .prefix : .name) ?? ""
  }

  @objc private func modeChanged(_ sender: NSSegmentedControl) {
    let mode: TabTitleEditorState.Mode = sender.selectedSegment == 1 ? .prefix : .name
    guard mode != editingMode else { return }
    editingMode = mode
    isChangingMode = true
    defer { isChangingMode = false }
    titleField?.placeholderString = mode == .name ? L("标签名称") : L("标签前缀")
    if mode == .name, let tab, case .name(let value) = tab.tabTitleOverride {
      titleField?.stringValue = value
    } else if mode == .name {
      titleField?.stringValue = tab?.automaticTitleForNaming ?? ""
    } else {
      titleField?.stringValue = tab?.titleEditorState.prefix ?? ""
    }
    view.window?.makeFirstResponder(titleField)
  }

  @objc private func commitName(_ sender: NSTextField) {
    guard !isChangingMode, !isDismissing else { return }
    guard targetIsCurrent else { dismiss(); return }
    let override: TerminalTitleOverride = modeControl?.selectedSegment == 1
      ? .prefix(sender.stringValue) : .name(sender.stringValue)
    tab?.setTabTitleOverride(override)
    sender.stringValue = tab?.titleEditorState.text(
      for: modeControl?.selectedSegment == 1 ? .prefix : .name) ?? ""
    model.persistWorkspace()
  }

  private func resetName() {
    guard targetIsCurrent else { dismiss(); return }
    tab?.setTabTitleOverride(.automatic)
    editingMode = .name
    modeControl?.selectedSegment = 0
    modeControl?.needsDisplay = true
    titleField?.stringValue = ""
    titleField?.placeholderString = L("标签名称")
    model.persistWorkspace()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
    if command == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
    if command == #selector(NSResponder.insertTab(_:)) {
      menuPresenter.close()
      view.window?.makeFirstResponder(navigationRows.first(where: \.isEnabled))
      return true
    }
    return false
  }

  override func viewWillDisappear() {
    isDismissing = true
    stopDismissalMonitoring()
    gitLoadTask?.cancel()
    menuPresenter.close()
    super.viewWillDisappear()
  }
}
