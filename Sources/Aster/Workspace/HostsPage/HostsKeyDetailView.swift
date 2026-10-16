// 「主机 → 密钥」子页右侧的详情面板：一把密钥的完整公开信息（类型、指纹、公钥、来源、使用它的主机）
// 与全部动作按钮。只显示公开信息，私钥从不进入界面。
import AppKit
import AsterCore

/// 密钥详情面板。内容由 `show(_:isBusy:)` 按行数据整体重建，自身不持有可写状态。
@MainActor
final class HostsKeyDetailView: NSView {
  /// 面板上各按钮的动作，由页面控制器提供。
  struct Handlers {
    var copyPublicKey: () -> Void
    var rename: () -> Void
    var migrate: () -> Void
    var deleteOriginal: () -> Void
    var delete: () -> Void
    var close: () -> Void
  }

  /// 面板宽度（默认字号档）。
  static let width: CGFloat = 340

  private let handlers: Handlers
  private let background = HostsPageFilledView(fillColor: HostsPagePalette.card, cornerRadius: 12)
  private let scrollView = NSScrollView()
  private let stack = NSStackView()
  /// 底部固定的动作区；内容再长也不会把按钮挤出可视范围。
  private let footer = NSStackView()
  /// 当前显示的密钥；测试与页面据此判断面板内容。
  private(set) var row: SSHVaultKeyRow?
  /// 动作按钮（测试按 identifier 读取可用状态）。
  private(set) var actionButtons: [HostsPagePillButton] = []

  /// 搭好空面板；内容在 `show` 时填充。
  init(handlers: Handlers) {
    self.handlers = handlers
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("hosts-keys-detail")
    buildLayout()
  }

  required init?(coder: NSCoder) { nil }

  /// 圆角底色 + 可滚动的内容栈 + 底部固定动作区。
  private func buildLayout() {
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)
    background.pinEdges(to: self)
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = document
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    addSubview(scrollView)
    let divider = HostsPageFilledView(fillColor: AsterTheme.hairline.withAlphaComponent(0.5), cornerRadius: 0)
    footer.orientation = .vertical
    footer.alignment = .leading
    footer.spacing = 6
    for view in [divider, footer] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    let clip = scrollView.contentView
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
      divider.heightAnchor.constraint(equalToConstant: 1),
      divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
      footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
    ])
  }

  /// 外观或主题切换后让底色按新外观重画。
  func refreshAppearance() { background.needsDisplay = true }

  // MARK: - 内容

  /// 显示一把密钥。`isBusy` 时会等待用户或子进程的动作按钮不可用，避免与进行中的动作交叠。
  func show(_ row: SSHVaultKeyRow, isBusy: Bool) {
    self.row = row
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    actionButtons = []
    add(makeHeader(row))
    let badges = makeHostsKeyBadges(row)
    if !badges.isEmpty {
      let badgeRow = NSStackView(views: badges)
      badgeRow.spacing = 5
      add(badgeRow)
    }
    if row.keychainMissing {
      add(makeNote(L("钥匙串里找不到这把私钥，连接时会跳过它。请删除后重新导入。"), color: .systemRed))
    }
    add(makeField(L("类型"), row.key.algorithm, identifier: "hosts-keys-detail-algorithm"))
    add(makeField(L("指纹"), row.key.fingerprint, monospaced: true, identifier: "hosts-keys-detail-fingerprint"))
    add(makeField(L("公钥"), row.key.publicKey, monospaced: true, identifier: "hosts-keys-detail-public-key"))
    if !row.key.comment.isEmpty { add(makeField(L("注释"), row.key.comment, identifier: "hosts-keys-detail-comment")) }
    add(makeField(L("来源"), row.originText, identifier: "hosts-keys-detail-origin"))
    add(makeField(
      L("添加时间"), row.key.createdAt.formatted(date: .abbreviated, time: .shortened),
      identifier: "hosts-keys-detail-created"))
    add(makeField(
      L("使用它的主机（\(String(row.usedBy.count))）"),
      row.usedBy.isEmpty ? L("还没有主机使用这把密钥。在主机设置的“保险库密钥”里勾选它。") : row.usedBy.joined(separator: "、"),
      identifier: "hosts-keys-detail-used-by"))
    footer.setViews(makeActionRows(row, isBusy: isBusy), in: .top)
  }

  /// 把一个视图加进内容栈并撑满宽度。
  private func add(_ view: NSView) {
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  /// 顶部：钥匙图标块、名称与关闭按钮。
  private func makeHeader(_ row: SSHVaultKeyRow) -> NSView {
    let tile = HostsPageFilledView(
      fillColor: row.keychainMissing ? .systemRed : AsterTheme.accent, cornerRadius: 9)
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(15), weight: .semibold))
    icon.contentTintColor = .white
    icon.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(icon)
    let title = makeLabel(row.key.label, size: 15, weight: .semibold, color: AsterTheme.ink)
    title.identifier = NSUserInterfaceItemIdentifier("hosts-keys-detail-title")
    title.lineBreakMode = .byWordWrapping
    title.maximumNumberOfLines = 2
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let close = IconHoverButton(symbol: "xmark", accessibilityDescription: L("关闭")) { [handlers] in
      handlers.close()
    }
    close.identifier = NSUserInterfaceItemIdentifier("hosts-keys-detail-close")
    close.toolTip = L("关闭")
    let header = NSView()
    for view in [tile, title, close] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      header.addSubview(view)
    }
    let tileSize = InterfaceScale.length(38)
    NSLayoutConstraint.activate([
      tile.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      tile.topAnchor.constraint(equalTo: header.topAnchor),
      tile.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
      tile.widthAnchor.constraint(equalToConstant: tileSize),
      tile.heightAnchor.constraint(equalToConstant: tileSize),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
      title.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
      title.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor),
      title.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
      close.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      close.topAnchor.constraint(equalTo: header.topAnchor),
      close.widthAnchor.constraint(equalToConstant: InterfaceScale.length(24)),
      close.heightAnchor.constraint(equalToConstant: InterfaceScale.length(24)),
    ])
    return header
  }

  /// 一个「小标题 + 可选中的值」字段；值可以换行，长公钥不会被截断。
  private func makeField(_ caption: String, _ value: String, monospaced: Bool = false, identifier: String) -> NSView {
    let captionLabel = makeLabel(caption, size: 11, weight: .medium, color: AsterTheme.tertiaryInk)
    let valueLabel = makeLabel(value, size: monospaced ? 11 : 12, color: AsterTheme.ink, monospaced: monospaced)
    valueLabel.identifier = NSUserInterfaceItemIdentifier(identifier)
    valueLabel.isSelectable = true
    valueLabel.lineBreakMode = monospaced ? .byCharWrapping : .byWordWrapping
    valueLabel.maximumNumberOfLines = 0
    valueLabel.cell?.wraps = true
    valueLabel.preferredMaxLayoutWidth = InterfaceScale.length(Self.width) - 36
    let field = NSStackView(views: [captionLabel, valueLabel])
    field.orientation = .vertical
    field.alignment = .leading
    field.spacing = 3
    valueLabel.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
    return field
  }

  /// 一段提示文字（缺失私钥等）。
  private func makeNote(_ text: String, color: NSColor) -> NSTextField {
    let note = makeLabel(text, size: 11.5, color: color)
    note.lineBreakMode = .byWordWrapping
    note.maximumNumberOfLines = 0
    note.preferredMaxLayoutWidth = InterfaceScale.length(Self.width) - 36
    return note
  }

  /// 底部动作区，按分量分三行：复制公钥 / 重命名；改用保险库密钥；删除原文件 / 删除（红色）。
  /// 删除类按钮在 `isBusy` 时不可用：它们在服务里互斥，连点只会被拒。
  private func makeActionRows(_ row: SSHVaultKeyRow, isBusy: Bool) -> [NSView] {
    let copy = makeAction(L("复制公钥"), symbol: "doc.on.doc", id: "copy", handler: handlers.copyPublicKey)
    let rename = makeAction(L("重命名…"), symbol: "pencil", id: "rename", handler: handlers.rename)
    var rows: [[HostsPagePillButton]] = [[copy, rename]]
    if !row.migratableHosts.isEmpty {
      rows.append([makeAction(
        L("改用保险库密钥（\(String(row.migratableHosts.count)) 台主机）…"), symbol: "arrow.triangle.swap",
        id: "migrate", handler: handlers.migrate)])
    }
    var danger: [HostsPagePillButton] = []
    if row.canDeleteOriginal {
      danger.append(makeAction(
        L("删除原文件…"), symbol: "doc.badge.ellipsis", id: "delete-original", handler: handlers.deleteOriginal))
    }
    danger.append(makeAction(L("删除…"), symbol: "trash", id: "delete", handler: handlers.delete))
    for button in danger {
      button.contentTintColor = .systemRed
      button.isEnabled = !isBusy
      button.alphaValue = button.isEnabled ? 1 : 0.45
    }
    rows.append(danger)
    actionButtons = rows.flatMap { $0 }
    return rows.map { buttons in
      let line = NSStackView(views: buttons)
      line.orientation = .horizontal
      line.spacing = 8
      return line
    }
  }

  /// 一个动作按钮。
  private func makeAction(_ title: String, symbol: String, id: String, handler: @escaping () -> Void) -> HostsPagePillButton {
    let button = HostsPagePillButton(title: title, symbol: symbol, handler: handler)
    button.identifier = NSUserInterfaceItemIdentifier("hosts-keys-detail-\(id)")
    return button
  }
}
