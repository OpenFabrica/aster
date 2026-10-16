// 「主机 → 密钥」子页的密钥卡片与状态徽标：钥匙图标块、名称、类型与短指纹、使用情况与警示。
// 配色沿用 `HostsPagePalette`，与主机卡片同一观感。
import AppKit
import AsterCore

/// 卡片与详情面板共用的小徽标（「2 台主机使用」「钥匙串中缺失」等）。
@MainActor
final class HostsKeyBadgeView: NSView {
  /// 徽标语气：普通、警示（橙）、危险（红）。
  enum Tone {
    case neutral
    case warning
    case danger
  }

  private let tone: Tone
  private let label: NSTextField

  /// `text` 为徽标文字，`toolTip` 给出完整说明。
  init(text: String, tone: Tone, toolTip: String? = nil) {
    self.tone = tone
    label = makeLabel(text, size: 10.5, weight: .medium, color: AsterTheme.secondaryInk)
    super.init(frame: .zero)
    self.toolTip = toolTip
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.cornerCurve = .continuous
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(text)
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  var text: String { label.stringValue }

  override var wantsUpdateLayer: Bool { true }

  /// 外观切换后按新外观重新解析底色。
  override func updateLayer() { applyStyle() }

  /// 文字色与浅底色按语气取；底色是同色低透明度，明暗两种外观都看得清。
  private func applyStyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let color: NSColor = switch tone {
      case .neutral: AsterTheme.secondaryInk
      case .warning: .systemOrange
      case .danger: .systemRed
      }
      label.textColor = color
      layer?.backgroundColor = color.withAlphaComponent(tone == .neutral ? 0.12 : 0.16).cgColor
    }
  }
}

/// 一行徽标。按行数据生成，没有要提示的状态时返回空数组。
@MainActor
func makeHostsKeyBadges(_ row: SSHVaultKeyRow) -> [HostsKeyBadgeView] {
  var badges: [HostsKeyBadgeView] = []
  if row.keychainMissing {
    badges.append(HostsKeyBadgeView(
      text: L("钥匙串中缺失"), tone: .danger,
      toolTip: L("钥匙串里找不到这把私钥，连接时会跳过它。请删除后重新导入。")))
  }
  if !row.usedBy.isEmpty {
    badges.append(HostsKeyBadgeView(
      text: L("\(String(row.usedBy.count)) 台主机使用"), tone: .neutral,
      toolTip: row.usedBy.joined(separator: "、")))
  }
  if row.canDeleteOriginal {
    badges.append(HostsKeyBadgeView(
      text: L("原文件仍在"), tone: .warning,
      toolTip: L("原私钥文件仍在磁盘上：\(row.importedFromDisplay ?? "")")))
  }
  return badges
}

/// 卡片上的算法简称：`ssh-ed25519` → `ED25519`，其余去掉 `ssh-` 前缀后大写。
func hostsKeyAlgorithmName(_ algorithm: String) -> String {
  if algorithm.hasPrefix("ecdsa-sha2-nistp") { return "ECDSA P-\(algorithm.dropFirst("ecdsa-sha2-nistp".count))" }
  let trimmed = algorithm.hasPrefix("ssh-") ? String(algorithm.dropFirst(4)) : algorithm
  return trimmed.uppercased()
}

/// 密钥卡片。单击选中（打开详情面板），右键弹出 `menuProvider` 的菜单。
@MainActor
final class HostsKeyCardView: NSView {
  /// 卡片高度（默认字号档）：标题、类型行与徽标行。
  static let height: CGFloat = 78

  let row: SSHVaultKeyRow
  private let onSelect: () -> Void
  private let menuProvider: () -> NSMenu
  private let tile = NSView()
  private var tracking: NSTrackingArea?
  private var pressedInside = false
  /// 选中时画强调色描边。
  var isSelected = false {
    didSet { if isSelected != oldValue { applyStyle() } }
  }
  private var hovered = false {
    didSet { if hovered != oldValue { applyStyle() } }
  }

  /// 按一行数据构建卡片。
  init(row: SSHVaultKeyRow, isSelected: Bool, onSelect: @escaping () -> Void, menuProvider: @escaping () -> NSMenu) {
    self.row = row
    self.onSelect = onSelect
    self.menuProvider = menuProvider
    self.isSelected = isSelected
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("hosts-keys-card-\(row.id.uuidString)")
    toolTip = row.key.fingerprint
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(row.key.label)
    setAccessibilityHelp("\(row.key.algorithm) \(row.key.fingerprint)")
    buildSubviews()
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 图标块 + 文字列（名称 / 类型与短指纹 / 徽标）。
  private func buildSubviews() {
    tile.wantsLayer = true
    tile.layer?.cornerRadius = 9
    tile.layer?.cornerCurve = .continuous
    tile.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tile)
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(15), weight: .semibold))
    icon.contentTintColor = .white
    icon.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(icon)

    let title = makeLabel(row.key.label, size: 13.5, weight: .medium, color: AsterTheme.ink)
    title.identifier = NSUserInterfaceItemIdentifier("hosts-keys-card-title")
    let detail = makeLabel(
      "\(hostsKeyAlgorithmName(row.key.algorithm)) · \(SSHVaultKeyRow.shortFingerprint(row.key.fingerprint))",
      size: 11.5, color: AsterTheme.secondaryInk)
    var lines: [NSView] = [title, detail]
    let badges = makeHostsKeyBadges(row)
    if !badges.isEmpty {
      let badgeRow = NSStackView(views: badges)
      badgeRow.spacing = 5
      badgeRow.identifier = NSUserInterfaceItemIdentifier("hosts-keys-card-badges")
      lines.append(badgeRow)
    }
    let column = NSStackView(views: lines)
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 3
    column.setCustomSpacing(5, after: detail)
    column.translatesAutoresizingMaskIntoConstraints = false
    column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for label in [title, detail] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    addSubview(column)

    let tileSize = InterfaceScale.length(38)
    NSLayoutConstraint.activate([
      tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      tile.centerYAnchor.constraint(equalTo: centerYAnchor),
      tile.widthAnchor.constraint(equalToConstant: tileSize),
      tile.heightAnchor.constraint(equalToConstant: tileSize),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      column.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
      column.centerYAnchor.constraint(equalTo: centerYAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
    ])
  }

  // MARK: - 交互

  /// 记下按下；松开时仍在卡片内才算点击，拖出再松开等于取消。
  override func mouseDown(with event: NSEvent) {
    pressedInside = true
    applyStyle()
  }

  /// 松开时仍在卡片内才选中。
  override func mouseUp(with event: NSEvent) {
    guard pressedInside else { return }
    pressedInside = false
    applyStyle()
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect() }
  }

  override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

  /// 辅助功能「按下」等同于单击。
  override func accessibilityPerformPress() -> Bool {
    onSelect()
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

  /// 悬停、按下或选中时加深底色；选中再加强调色描边。缺私钥的密钥图标块用红色提示。
  private func applyStyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let active = hovered || pressedInside || isSelected
      layer?.backgroundColor = (active ? HostsPagePalette.cardHover : HostsPagePalette.card).cgColor
      layer?.borderWidth = isSelected ? 1.5 : 0
      layer?.borderColor = AsterTheme.accent.cgColor
      tile.layer?.backgroundColor = (row.keychainMissing ? NSColor.systemRed : AsterTheme.accent).cgColor
    }
  }
}
