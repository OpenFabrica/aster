// 侧栏「工作区」上方的「主机」入口行，以及主机页在工作区内容区里的挂载。
import AppKit
import AsterCore
import Combine

/// 侧栏里的「主机」行：图标 + 「主机」+ 已保存主机数。样式与工作区行一致。
///
/// 与 `WorkspaceGroupRowView` 相同，单击在 mouseDown 立即派发：打开主机页会触发侧栏
/// 整树重建，等到 mouseUp 时这一行可能已被移出视图树。主机数由行自己订阅主机目录
/// 原地更新，hosts.json 变化不必为一个数字重建整个工作区。
@MainActor
final class HostsSidebarRowView: NSView {
  private let style: WorkspaceGroupRowStyle
  private let isSelected: Bool
  private let onSelect: () -> Void
  private let background = NSView()
  private var countLabel: NSTextField?
  private var hostsSubscription: AnyCancellable?
  private var tracking: NSTrackingArea?
  private var hovered = false {
    didSet { if hovered != oldValue { updateStyle() } }
  }

  /// `hostCount` 是已保存主机数；`isSelected` 表示主机页正在显示。
  init(
    directory: SSHHostDirectory, isSelected: Bool, style: WorkspaceGroupRowStyle,
    onSelect: @escaping () -> Void
  ) {
    self.style = style
    self.isSelected = isSelected
    self.onSelect = onSelect
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("workspace-sidebar-hosts-row")
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: InterfaceScale.length(30)).isActive = true
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(L("主机"))
    setAccessibilityValue(isSelected ? L("当前页面") : nil)

    background.wantsLayer = true
    background.layer?.cornerCurve = .continuous
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)

    let tint = isSelected ? style.activeForeground : style.foreground
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(11), weight: .medium))
    icon.contentTintColor = tint
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(icon)

    let name = makeLabel(L("主机"), size: 12.5, weight: isSelected ? style.activeWeight : .regular, color: tint)
    name.translatesAutoresizingMaskIntoConstraints = false
    addSubview(name)

    let count = makeLabel("", size: 10, color: AsterTheme.tertiaryInk, monospaced: true)
    count.identifier = NSUserInterfaceItemIdentifier("workspace-sidebar-hosts-count")
    count.translatesAutoresizingMaskIntoConstraints = false
    addSubview(count)
    countLabel = count
    updateCount(directory.savedHosts.count)
    // @Published 在 willSet 时发出，切到下一轮主队列再读新列表。
    hostsSubscription = directory.$hosts
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak directory] _ in
        guard let directory else { return }
        self?.updateCount(directory.savedHosts.count)
      }

    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(style.insets.leading)),
      background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(style.insets.trailing)),
      background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
      count.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
      count.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    updateStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 原地更新主机数。
  private func updateCount(_ count: Int) {
    countLabel?.stringValue = String(count)
    countLabel?.toolTip = L("\(String(count)) 台主机")
  }

  override func mouseDown(with event: NSEvent) { onSelect() }

  /// 辅助功能「按下」等同于单击。
  override func accessibilityPerformPress() -> Bool {
    onSelect()
    return true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  /// 选中用标签行的激活底色，悬停用悬停底色，其余透明。
  private func updateStyle() {
    let color: NSColor = isSelected ? style.activeBackground : (hovered ? style.hoverBackground : .clear)
    background.layer?.backgroundColor = color.cgColor
    background.layer?.cornerRadius = style.radius
  }
}

// MARK: - 控制器接线

extension WorkspaceViewController {
  /// 侧栏「主机」行。点击打开主机页；主机页已打开时再点等于回到终端。
  func makeHostsSidebarRow(theme: TerminalTheme) -> NSView {
    let presented = model.isHostsPagePresented
    return HostsSidebarRowView(
      directory: hostsDirectory, isSelected: presented,
      style: WorkspaceGroupRowStyle(theme: theme)
    ) { [weak self] in
      guard let self else { return }
      if self.model.isHostsPagePresented {
        self.model.dismissHostsPage()
      } else {
        self.model.presentHostsPage()
      }
    }
  }

  /// 内容区里的主机页：沿用终端工作区的容器卡片（外边距、底色、圆角），页面实例跨刷新复用。
  func makeHostsPageArea(_ page: HostsPageViewController) -> NSView {
    let style = preferences.activeTheme.style.container
    let margin = preferences.tabBarLayout == .vertical
      ? style.margin : (style.horizontalLayoutMargin ?? style.margin)
    let theme = preferences.activeTheme
    let wrapper = NSView()
    let container = NSView()
    container.identifier = NSUserInterfaceItemIdentifier("hosts-page-container")
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(
      theme.resolvedColor(forSlot: "container.background")
        ?? style.background ?? theme.palette.containerBackground
    ).cgColor
    container.layer?.cornerRadius = style.radius
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = style.radius > 0
    container.layer?.borderWidth = style.borderWidth
    container.layer?.borderColor = NSColor(
      theme.resolvedColor(forSlot: "container.border")
        ?? style.borderColor ?? theme.palette.containerBackground
    ).cgColor
    wrapper.addSubview(container)
    container.pinEdges(to: wrapper, insets: NSEdgeInsets(margin))
    if page.parent !== self { addChild(page) }
    container.addSubview(page.view)
    page.view.translatesAutoresizingMaskIntoConstraints = false
    page.view.pinEdges(to: container)
    return wrapper
  }
}
