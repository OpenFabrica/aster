// 「已知主机」子页的一行记录与小徽章：覆盖的主机、算法、可选中的 SHA256 指纹、行号与标记。
import AppKit
import AsterCore

/// 「已知主机」页用到的配色；与 `HostsPagePalette` 一样在动态色里按外观解析。
@MainActor
enum KnownHostsPagePalette {
  /// 已吊销记录的图标块与徽章底色。
  static let revokedFill = NSColor(name: nil) { appearance in
    NSColor.systemRed.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.22 : 0.13)
  }
  /// 读取失败横幅底色。
  static let warningFill = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .warning, appearance: appearance).withAlphaComponent(0.14)
  }
}

/// 圆角小徽章（「系统级 · 只读」「已吊销」等）。
@MainActor
func makeKnownHostsBadge(_ text: String, identifier: String, destructive: Bool = false) -> NSView {
  let fill = HostsPageFilledView(
    fillColor: destructive ? KnownHostsPagePalette.revokedFill : HostsPagePalette.control, cornerRadius: 5)
  fill.identifier = NSUserInterfaceItemIdentifier(identifier)
  let label = makeLabel(
    text, size: 10.5, weight: .medium, color: destructive ? .systemRed : AsterTheme.secondaryInk)
  label.translatesAutoresizingMaskIntoConstraints = false
  fill.addSubview(label)
  fill.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    label.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: 7),
    label.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -7),
    label.topAnchor.constraint(equalTo: fill.topAnchor, constant: 2.5),
    label.bottomAnchor.constraint(equalTo: fill.bottomAnchor, constant: -2.5),
  ])
  fill.setContentHuggingPriority(.required, for: .horizontal)
  fill.setContentCompressionResistancePriority(.required, for: .horizontal)
  return fill
}

/// 一条 known_hosts 记录。指纹可以选中复制；右键菜单可复制指纹、主机，或删除（仅可写文件）。
@MainActor
final class KnownHostsEntryRowView: NSView {
  let row: KnownHostsPageRow
  /// 删除按钮；记录所在文件不可写时为 nil。
  private(set) var deleteButton: HostsPagePillButton?
  private let onDelete: () -> Void

  /// `deleteEnabled` 为 false 时（另一次删除还在进行）按钮置灰。
  init(row: KnownHostsPageRow, deleteEnabled: Bool, onDelete: @escaping () -> Void) {
    self.row = row
    self.onDelete = onDelete
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("known-hosts-row-\(row.entry.line)")
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(row.title)
    build(deleteEnabled: deleteEnabled)
  }

  required init?(coder: NSCoder) { nil }

  /// 图标块 + 两行文字 + 标记徽章 + 删除按钮。
  private func build(deleteEnabled: Bool) {
    let entry = row.entry
    let revoked = entry.marker == "revoked"
    let tile = HostsPageFilledView(
      fillColor: revoked ? KnownHostsPagePalette.revokedFill : HostsPagePalette.control, cornerRadius: 8)
    let symbol =
      switch entry.marker {
      case "revoked": "xmark.shield"
      case "certAuthority": "checkmark.seal"
      default: "key"
      }
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(13), weight: .medium))
    icon.contentTintColor = revoked ? .systemRed : AsterTheme.secondaryInk
    icon.translatesAutoresizingMaskIntoConstraints = false
    tile.addSubview(icon)
    tile.translatesAutoresizingMaskIntoConstraints = false

    let title = makeLabel(row.title, size: 13, weight: .medium, color: AsterTheme.ink)
    title.toolTip = row.title
    // 压缩优先级高于栈视图的贴合优先级（250），否则文字会被栈挤成 0 宽；行宽不够时才截断。
    title.setContentCompressionResistancePriority(.init(500), for: .horizontal)
    let text = NSStackView(views: [title, makeDetailLine()])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.translatesAutoresizingMaskIntoConstraints = false

    var trailing: [NSView] = []
    if entry.marker == "revoked" {
      trailing.append(makeKnownHostsBadge(L("已吊销"), identifier: "known-hosts-revoked", destructive: true))
    }
    if entry.marker == "certAuthority" {
      trailing.append(makeKnownHostsBadge(L("证书颁发机构"), identifier: "known-hosts-cert-authority"))
    }
    if row.removable {
      let button = HostsPagePillButton(title: "", symbol: "trash", showsBackground: false) { [weak self] in
        self?.onDelete()
      }
      button.identifier = NSUserInterfaceItemIdentifier("known-hosts-delete-\(entry.line)")
      button.toolTip = L("删除…")
      button.setAccessibilityLabel(L("删除…"))
      button.isEnabled = deleteEnabled
      button.contentTintColor = AsterTheme.secondaryInk
      deleteButton = button
      trailing.append(button)
    }
    let accessory = NSStackView(views: trailing)
    accessory.orientation = .horizontal
    accessory.spacing = 8
    accessory.setContentHuggingPriority(.required, for: .horizontal)
    accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
    accessory.translatesAutoresizingMaskIntoConstraints = false

    for subview in [tile, text, accessory] as [NSView] { addSubview(subview) }
    let tileSize = InterfaceScale.length(30)
    NSLayoutConstraint.activate([
      tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      tile.centerYAnchor.constraint(equalTo: centerYAnchor),
      tile.widthAnchor.constraint(equalToConstant: tileSize),
      tile.heightAnchor.constraint(equalToConstant: tileSize),
      icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

      text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
      text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      text.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -12),

      accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  /// 第二行：算法 · 指纹 · 第 N 行 · 注释。指纹用等宽字体且可选中，便于和服务器上的 `ssh-keygen -lf` 核对。
  private func makeDetailLine() -> NSView {
    let entry = row.entry
    let fingerprint = makeLabel(entry.fingerprint, size: 11.5, color: AsterTheme.secondaryInk, monospaced: true)
    fingerprint.isSelectable = true
    fingerprint.lineBreakMode = .byTruncatingMiddle
    fingerprint.identifier = NSUserInterfaceItemIdentifier("known-hosts-fingerprint-\(entry.line)")
    fingerprint.setContentCompressionResistancePriority(.init(500), for: .horizontal)
    var parts: [NSView] = [
      makeLabel(entry.algorithm, size: 11.5, color: AsterTheme.secondaryInk), separatorDot(), fingerprint,
      separatorDot(), makeLabel(L("第 \(String(entry.line)) 行"), size: 11.5, color: AsterTheme.tertiaryInk),
    ]
    if let comment = entry.comment, !comment.isEmpty {
      let label = makeLabel(comment, size: 11.5, color: AsterTheme.tertiaryInk)
      // 行宽不够时注释先截断，指纹尽量完整。
      label.setContentCompressionResistancePriority(.init(490), for: .horizontal)
      parts += [separatorDot(), label]
    }
    let line = NSStackView(views: parts)
    line.orientation = .horizontal
    line.spacing = 5
    return line
  }

  /// 第二行各段之间的「·」。
  private func separatorDot() -> NSTextField {
    makeLabel("·", size: 11.5, color: AsterTheme.tertiaryInk)
  }

  /// 右键菜单：复制指纹 / 复制主机 / 删除…（只在可写文件里）。
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let entry = row.entry
    menu.addItem(ActionMenuItem(title: L("复制指纹")) { Self.copy(entry.fingerprint) })
    let hosts = row.covered.joined(separator: "\n")
    if !hosts.isEmpty {
      menu.addItem(ActionMenuItem(title: L("复制主机")) { Self.copy(hosts) })
    }
    if row.removable {
      menu.addItem(.separator())
      let delete = ActionMenuItem(title: L("删除…")) { [weak self] in
        // 菜单还在追踪事件时开 sheet 会卡住菜单收尾；推到下一轮主循环。
        DispatchQueue.main.async { self?.onDelete() }
      }
      delete.isEnabled = deleteButton?.isEnabled ?? false
      menu.addItem(delete)
    }
    return menu
  }

  /// 写入剪贴板。
  private static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
