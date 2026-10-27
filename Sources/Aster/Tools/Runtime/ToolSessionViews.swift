// 工具会话的通用界面：根视图、提示（出错、停用、找不到）、运行中，以及运行前的授权提示。
import AppKit
import AsterCore

/// 工具会话的根视图：内容撑满；外观变化时回调（网页工具据此收到 `theme` 事件）。
@MainActor
final class ToolSessionRootView: NSView {
  /// 明暗外观变化后调用。
  var onAppearanceChange: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }

  /// 当前外观对应的 `light` / `dark`。
  var appearanceName: String {
    effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
  }
}

/// 居中的一条提示：图标 + 可换行文字 + 可选按钮。出错时文字可选中，方便复制 stderr。
@MainActor
final class ToolSessionMessageView: NSView {
  /// 提示的种类，决定图标与颜色。
  enum Style {
    case info
    case success
    case error
  }

  init(text: String, style: Style, buttonTitle: String? = nil, action: (() -> Void)? = nil) {
    super.init(frame: .zero)
    let symbol =
      switch style {
      case .info: "info.circle"
      case .success: "checkmark.circle"
      case .error: "exclamationmark.triangle"
      }
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    icon.contentTintColor = style == .error ? AsterTheme.warning : AsterTheme.secondaryInk
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = NSFont.interface(ofSize: 12)
    label.textColor = style == .error ? AsterTheme.ink : AsterTheme.secondaryInk
    label.alignment = .center
    label.isSelectable = style == .error
    label.maximumNumberOfLines = 12
    var views: [NSView] = [icon, label]
    if let buttonTitle, let action {
      views.append(BuiltinToolLayout.button(buttonTitle, handler: action))
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
      stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
      label.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

/// 运行中：转圈 + 一行说明。
@MainActor
final class ToolSessionRunningView: NSView {
  private let spinner = NSProgressIndicator()

  init(text: String) {
    super.init(frame: .zero)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.startAnimation(nil)
    let label = makeLabel(text, size: 12, color: AsterTheme.secondaryInk)
    let stack = NSStackView(views: [spinner, label])
    stack.orientation = .horizontal
    stack.spacing = 8
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 移出窗口时停掉动画，避免隐藏的转圈继续占用重绘。
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
  }
}

/// 运行前的授权提示：说明原因、列出要用的权限，点按钮后才弹安装确认。
@MainActor
final class ToolApprovalPromptView: NSView {
  private let button: ActionButton

  init(manifest: ToolManifest, reason: ToolApprovalReason, onApprove: @escaping () -> Void) {
    button = BuiltinToolLayout.button(L("允许并运行…"), handler: onApprove)
    super.init(frame: .zero)
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
    icon.contentTintColor = AsterTheme.accent
    let title = NSTextField(wrappingLabelWithString: L("「\(manifest.name)」需要你的允许才能运行"))
    title.font = NSFont.interface(ofSize: 13, weight: .semibold)
    title.textColor = AsterTheme.ink
    title.alignment = .center
    let detail = NSTextField(wrappingLabelWithString: Self.reasonText(reason))
    detail.font = NSFont.interface(ofSize: 12)
    detail.textColor = AsterTheme.secondaryInk
    detail.alignment = .center
    var views: [NSView] = [icon, title, detail]
    let permissions = ToolPluginTrust.permissionsRequiringConsent(manifest)
    if !permissions.isEmpty { views.append(Self.permissionSummary(permissions)) }
    views.append(button)
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.setCustomSpacing(12, after: views[views.count - 2])
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
      title.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
      detail.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 确认框打开期间禁用按钮，防止重复弹出。
  func setBusy(_ busy: Bool) {
    button.isEnabled = !busy
  }

  /// 原因说明。
  static func reasonText(_ reason: ToolApprovalReason) -> String {
    switch reason {
    case .firstRun:
      L("第一次运行这个插件，要先确认它可以使用的权限。")
    case .filesChanged:
      L("插件的文件和上次允许时不一样了，需要重新确认。")
    case .permissionsAdded(let added):
      L("插件多要了这些权限：\(added.map(\.localizedTitle).joined(separator: L("、")))")
    case .networkDomainsAdded(let domains):
      L("插件要访问更多网站：\(domains.joined(separator: L("、")))")
    }
  }

  /// 权限一览：一行若干个「圆点 + 名称」，按风险从高到低。
  private static func permissionSummary(_ permissions: [ToolPermission]) -> NSView {
    let items = permissions.map { permission -> NSView in
      let dot = ToolRiskDotView(risk: permission.risk)
      let label = makeLabel(permission.localizedTitle, size: 11, color: AsterTheme.secondaryInk)
      let item = NSStackView(views: [dot, label])
      item.orientation = .horizontal
      item.alignment = .centerY
      item.spacing = 5
      return item
    }
    let column = NSStackView(views: items)
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 4
    return column
  }
}
