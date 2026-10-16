// 主机页的卡片：左侧圆角图标块，右侧标题与副标题。分组卡片与主机卡片共用这一个视图。
import AppKit
import AsterCore

/// 一张卡片要显示的内容。
struct HostsPageCardContent {
  /// 稳定标识（测试与辅助功能用），例如 `hosts-page-host-<uuid>`。
  var identifier: String
  var title: String
  var subtitle: String
  /// 图标块里的 SF Symbol。
  var symbol: String
  /// 标题右侧的小标签（例如「远程机器」）；nil 不显示。
  var badge: String?
  /// 列表模式下卡片右侧的补充文字（连接串）；网格模式不显示。
  var trailingDetail: String?
  var toolTip: String?
}

/// 主机页卡片。松开时仍在卡片内触发 `onOpen`（`opensOnDoubleClick` 为 true 时要双击，
/// 单击只给悬停/按下反馈）；右键弹出 `menuProvider` 的菜单；有 `onEdit` 时悬停显示右侧铅笔按钮。
@MainActor
final class HostsPageCardView: NSView {
  /// 卡片高度（默认字号档）。
  static let height: CGFloat = 64

  let content: HostsPageCardContent
  /// 为 true 时只有双击才触发 `onOpen`。主机卡片用它：单击误触就开一个 SSH 标签太重。
  let opensOnDoubleClick: Bool
  private let onOpen: () -> Void
  private let menuProvider: (() -> NSMenu)?
  private let editButton: IconHoverButton?
  private let detailLabel: NSTextField?
  /// 左侧圆角图标块；底色是强调色，外观切换时要重新解析。
  private let tile = NSView()
  private var tracking: NSTrackingArea?
  private var pressedInside = false
  private var hovered = false {
    didSet { if hovered != oldValue { applyStyle() } }
  }

  /// 构建卡片；`showsTrailingDetail` 为 true（列表模式）时显示连接串。
  /// `editTitle` 是铅笔按钮的辅助功能名称与提示（主机卡片「编辑主机…」，分组卡片「重命名分组…」）。
  init(
    content: HostsPageCardContent, showsTrailingDetail: Bool, opensOnDoubleClick: Bool = false,
    onOpen: @escaping () -> Void, onEdit: (() -> Void)? = nil, editTitle: String = L("编辑主机…"),
    menuProvider: (() -> NSMenu)? = nil
  ) {
    self.content = content
    self.opensOnDoubleClick = opensOnDoubleClick
    self.onOpen = onOpen
    self.menuProvider = menuProvider
    editButton = onEdit.map { edit in
      IconHoverButton(symbol: "pencil", accessibilityDescription: editTitle, handler: edit)
    }
    detailLabel = showsTrailingDetail
      ? content.trailingDetail.map { makeLabel($0, size: 11.5, color: AsterTheme.tertiaryInk, monospaced: true) }
      : nil
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier(content.identifier)
    toolTip = content.toolTip
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(content.title)
    setAccessibilityHelp(content.subtitle)
    buildSubviews()
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 图标块 + 标题列 + （列表模式）连接串 + （悬停）编辑按钮。
  private func buildSubviews() {
    tile.wantsLayer = true
    tile.layer?.cornerRadius = 9
    tile.layer?.cornerCurve = .continuous
    tile.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tile)
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(15), weight: .semibold))
    icon.contentTintColor = .white
    icon.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(icon)

    let title = makeLabel(content.title, size: 13.5, weight: .medium, color: AsterTheme.ink)
    title.identifier = NSUserInterfaceItemIdentifier("\(content.identifier)-title")
    let subtitle = makeLabel(content.subtitle, size: 11.5, color: AsterTheme.secondaryInk)
    subtitle.identifier = NSUserInterfaceItemIdentifier("\(content.identifier)-subtitle")
    // 标题行：标题 + 可选小标签；标签不参与压缩，标题自己截断。
    let titleRow = NSStackView(views: [title])
    titleRow.orientation = .horizontal
    titleRow.spacing = 6
    titleRow.alignment = .centerY
    if let badge = content.badge {
      let pill = makeBadge(badge)
      pill.identifier = NSUserInterfaceItemIdentifier("\(content.identifier)-badge")
      titleRow.addArrangedSubview(pill)
    }
    let column = NSStackView(views: [titleRow, subtitle])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 2
    column.translatesAutoresizingMaskIntoConstraints = false
    column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for label in [title, subtitle] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(column)

    let tileSize = InterfaceScale.length(38)
    var constraints = [
      tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      tile.centerYAnchor.constraint(equalTo: centerYAnchor),
      tile.widthAnchor.constraint(equalToConstant: tileSize),
      tile.heightAnchor.constraint(equalToConstant: tileSize),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      column.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
      column.centerYAnchor.constraint(equalTo: centerYAnchor),
    ]
    // 右侧依次是编辑按钮与连接串；标题列让位给它们，自己截断。
    var trailingAnchorForColumn = trailingAnchor
    var trailingInset: CGFloat = 12
    if let editButton {
      editButton.translatesAutoresizingMaskIntoConstraints = false
      editButton.isHidden = true
      editButton.toolTip = editButton.accessibilityLabel()
      addSubview(editButton)
      constraints += [
        editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        editButton.widthAnchor.constraint(equalToConstant: InterfaceScale.length(26)),
        editButton.heightAnchor.constraint(equalToConstant: InterfaceScale.length(26)),
      ]
      trailingAnchorForColumn = editButton.leadingAnchor
      trailingInset = 8
    }
    if let detailLabel {
      detailLabel.translatesAutoresizingMaskIntoConstraints = false
      detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
      addSubview(detailLabel)
      constraints += [
        detailLabel.trailingAnchor.constraint(equalTo: trailingAnchorForColumn, constant: -trailingInset),
        detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: column.trailingAnchor, constant: 16),
      ]
    } else {
      constraints.append(
        column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchorForColumn, constant: -trailingInset))
    }
    NSLayoutConstraint.activate(constraints)
  }

  /// 强调色淡底的小圆角标签。
  private func makeBadge(_ text: String) -> NSView {
    let pill = HostsPageFilledView(fillColor: AsterTheme.accent.withAlphaComponent(0.14), cornerRadius: 5)
    let label = makeLabel(text, size: 10, weight: .semibold, color: AsterTheme.accent)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    pill.addSubview(label)
    pill.translatesAutoresizingMaskIntoConstraints = false
    pill.setContentCompressionResistancePriority(.required, for: .horizontal)
    pill.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
      label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1.5),
      label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1.5),
    ])
    return pill
  }

  // MARK: - 交互

  /// 记下按下位置；真正的打开动作等松开时再判断，拖出卡片再松开等于取消。
  override func mouseDown(with event: NSEvent) {
    pressedInside = true
    applyStyle()
  }

  /// 松开时仍在卡片内才打开；要求双击的卡片按 `clickCount` 过滤掉单击。
  override func mouseUp(with event: NSEvent) {
    guard pressedInside else { return }
    pressedInside = false
    applyStyle()
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point), Self.shouldOpen(clickCount: event.clickCount, doubleClick: opensOnDoubleClick)
    else { return }
    onOpen()
  }

  /// 这次松开是否算「打开」：单击卡片任意次数都行，双击卡片只认第二次（以及后续连击）。
  static func shouldOpen(clickCount: Int, doubleClick: Bool) -> Bool {
    doubleClick ? clickCount >= 2 : true
  }

  override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

  /// 辅助功能「按下」直接打开，不区分单击与双击。
  override func accessibilityPerformPress() -> Bool {
    onOpen()
    return true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  /// 外观切换后 CGColor 要按新外观重新解析。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyStyle()
  }

  /// 悬停或按下时加深底色并显示编辑按钮。CGColor 必须在当前外观上下文里解析。
  private func applyStyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let active = hovered || pressedInside
      layer?.backgroundColor = (active ? HostsPagePalette.cardHover : HostsPagePalette.card).cgColor
      tile.layer?.backgroundColor = AsterTheme.accent.cgColor
    }
    editButton?.isHidden = !hovered
  }
}
