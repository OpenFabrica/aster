// 插件安装确认：列出插件名、版本、来源、按风险排序的权限、域名与脚本命令，用户点「允许」才写入授权。
// 有可见窗口时挂成 sheet，否则单独弹一个面板；确认器是协议，测试注入假实现，不出真界面。
import AppKit
import AsterCore

/// 安装确认的场景。
enum ToolInstallPromptKind: Equatable {
  /// 从文件夹安装到插件目录。
  case install
  /// 登记开发目录（不复制）。
  case developmentFolder
  /// 已有插件运行前的确认：第一次运行、文件变了、权限或域名变多。
  case approval(ToolApprovalReason)
}

/// 安装确认要展示的内容。
struct ToolInstallPrompt: Equatable {
  let kind: ToolInstallPromptKind
  let manifest: ToolManifest
  let source: ToolPluginSource
  /// 插件来源路径。
  let directory: String
}

/// 询问用户是否允许插件；测试替换成直接返回结果的实现。
@MainActor
protocol ToolInstallApproving: AnyObject {
  /// 用户点「允许」返回 true；取消、关窗返回 false。
  func requestApproval(for prompt: ToolInstallPrompt, window: NSWindow?) async -> Bool
}

/// 用原生 sheet 询问用户。
@MainActor
final class ToolInstallSheetApprover: ToolInstallApproving {
  func requestApproval(for prompt: ToolInstallPrompt, window: NSWindow?) async -> Bool {
    let controller = ToolInstallSheetController(prompt: prompt)
    return await controller.present(attachedTo: window)
  }
}

/// 一次安装确认的面板与结果。`present` 返回前由调用方的 await 强持有。
@MainActor
final class ToolInstallSheetController: NSObject, NSWindowDelegate {
  /// 「允许」按钮在出现后这么久才可点，防止连按回车误授权。
  static let allowDelay: Duration = .milliseconds(600)

  let prompt: ToolInstallPrompt
  private let panel: NSPanel
  private var continuation: CheckedContinuation<Bool, Never>?
  private weak var parentWindow: NSWindow?
  private var allowButton: NSButton?

  init(prompt: ToolInstallPrompt) {
    self.prompt = prompt
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init()
    panel.title = L("插件授权")
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    let content = makeContent()
    panel.contentView = content
    // 面板不会按约束自动长高；按内容的理想尺寸设一次，换行文字靠 preferredMaxLayoutWidth 算出高度。
    content.layoutSubtreeIfNeeded()
    panel.setContentSize(content.fittingSize)
  }

  /// 弹出确认并等用户选择。`window` 可见时挂成 sheet，否则单独居中显示。
  func present(attachedTo window: NSWindow?) async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      if let window, window.isVisible {
        parentWindow = window
        window.beginSheet(panel) { [weak self] response in
          self?.complete(response == .OK)
        }
      } else {
        panel.center()
        panel.level = .modalPanel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
      }
      enableAllowAfterDelay()
    }
  }

  /// 关闭按钮等同于取消。
  func windowWillClose(_ notification: Notification) {
    complete(false)
  }

  // MARK: 结果

  /// 按钮动作：sheet 交给父窗口结束（结果在 sheet 回调里给出），独立面板直接关闭。
  private func finish(_ allowed: Bool) {
    if let parentWindow, panel.sheetParent != nil {
      parentWindow.endSheet(panel, returnCode: allowed ? .OK : .cancel)
    } else {
      complete(allowed)
      panel.orderOut(nil)
    }
  }

  /// 只回一次结果。
  private func complete(_ allowed: Bool) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(returning: allowed)
  }

  /// 「允许」先禁用一小会儿：确认框常紧跟在回车或点击之后出现，避免同一下按键直接授权。
  private func enableAllowAfterDelay() {
    allowButton?.isEnabled = false
    Task { [weak self] in
      do {
        try await Task.sleep(for: Self.allowDelay)
      } catch {
        return
      }
      self?.allowButton?.isEnabled = true
    }
  }

  // MARK: 内容

  /// 自上而下：标题、原因、来源、权限、域名、命令、说明、按钮。
  private func makeContent() -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
    stack.addArrangedSubview(makeHeader())
    if let reason = reasonText() { stack.addArrangedSubview(wrapping(reason, size: 12, color: SettingsTheme.ink)) }
    stack.addArrangedSubview(section(L("来源"), [pathLabel(prompt.directory)]))
    stack.addArrangedSubview(section(L("需要的权限"), permissionRows()))
    if !prompt.manifest.network.isEmpty {
      let domains = prompt.manifest.network.joined(separator: L("、"))
      stack.addArrangedSubview(section(L("可以访问的网站"), [wrapping(domains, size: 12, color: SettingsTheme.ink)]))
    }
    let commands = commandLines()
    if !commands.isEmpty { stack.addArrangedSubview(section(L("会运行的命令"), commands)) }
    stack.addArrangedSubview(
      wrapping(L("之后插件升级时，如果要的权限变多了，会再问你一次。"), size: 11, color: SettingsTheme.tertiaryInk))
    stack.addArrangedSubview(makeButtons())
    for view in stack.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }
    stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
    return stack
  }

  /// 图标 + 标题 + 版本与 id。
  private func makeHeader() -> NSView {
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
    icon.contentTintColor = SettingsTheme.accent
    icon.setContentHuggingPriority(.required, for: .horizontal)
    let title = wrapping(titleText(), size: 15, color: SettingsTheme.ink, weight: .semibold)
    let detail = makeLabel(
      L("版本 \(prompt.manifest.version) · \(prompt.manifest.id)"), size: 11, color: SettingsTheme.secondaryInk)
    let texts = NSStackView(views: [title, detail])
    texts.orientation = .vertical
    texts.alignment = .leading
    texts.spacing = 3
    let row = NSStackView(views: [icon, texts])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 12
    return row
  }

  /// 标题随场景变化。
  private func titleText() -> String {
    let name = prompt.manifest.name
    return switch prompt.kind {
    case .install: L("安装插件「\(name)」？")
    case .developmentFolder: L("登记开发目录「\(name)」？")
    case .approval: L("允许插件「\(name)」运行？")
    }
  }

  /// 运行前确认的原因说明；安装与登记没有。
  private func reasonText() -> String? {
    guard case .approval(let reason) = prompt.kind else { return nil }
    switch reason {
    case .firstRun:
      return L("这个插件第一次运行，需要你的允许。")
    case .filesChanged:
      return L("插件的文件和你上次允许时不一样了，请确认来源可信。")
    case .permissionsAdded(let added):
      let titles = added.map(\.localizedTitle).joined(separator: L("、"))
      return L("新版本多要了这些权限：\(titles)")
    case .networkDomainsAdded(let domains):
      return L("新版本要访问更多网站：\(domains.joined(separator: L("、")))")
    }
  }

  /// 权限按风险从高到低，每行一个彩色圆点；没有权限时说明一句。
  private func permissionRows() -> [NSView] {
    let permissions = ToolPluginTrust.permissionsRequiringConsent(prompt.manifest)
    guard !permissions.isEmpty else {
      return [wrapping(L("不需要额外权限，只能在自己的界面里运行。"), size: 12, color: SettingsTheme.secondaryInk)]
    }
    return permissions.map { permission in
      let dot = ToolRiskDotView(risk: permission.risk)
      let title = makeLabel(permission.localizedTitle, size: 12, color: SettingsTheme.ink)
      let risk = makeLabel(Self.riskTitle(permission.risk), size: 11, color: SettingsTheme.tertiaryInk)
      let row = NSStackView(views: [dot, title, risk])
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 8
      return row
    }
  }

  /// 每个脚本功能一行：功能名 + 命令（按 POSIX 单引号规则显示，和实际传给程序的参数一致）。
  private func commandLines() -> [NSView] {
    let lines = prompt.manifest.features.compactMap { feature -> String? in
      guard case .script(let action) = feature.action else { return nil }
      // 分隔符走翻译表（`%@：%@`），英文界面用半角冒号。
      let command = action.command.map(Self.shellQuoted).joined(separator: " ")
      return L("\(feature.title)：\(command)")
    }
    let shown = lines.prefix(8).map { line -> NSView in
      let label = wrapping(line, size: 11, color: SettingsTheme.ink)
      label.font = NSFont.interfaceMonospaced(ofSize: 11)
      return label
    }
    guard lines.count > shown.count else { return Array(shown) }
    let more = L("还有 \(String(lines.count - shown.count)) 条命令")
    return Array(shown) + [wrapping(more, size: 11, color: SettingsTheme.secondaryInk)]
  }

  /// 底部按钮：「取消」响应 Esc，「允许」是默认按钮。
  private func makeButtons() -> NSView {
    let cancel = ActionButton(title: L("取消")) { [weak self] in self?.finish(false) }
    cancel.keyEquivalent = "\u{1b}"
    let allow = ActionButton(title: L("允许")) { [weak self] in self?.finish(true) }
    allow.keyEquivalent = "\r"
    allowButton = allow
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 8
    row.setViews([cancel, allow], in: .trailing)
    return row
  }

  /// 小标题 + 内容的分组。
  private func section(_ title: String, _ content: [NSView]) -> NSView {
    let header = makeLabel(title, size: 11, weight: .semibold, color: SettingsTheme.secondaryInk)
    let stack = NSStackView(views: [header] + content)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    return stack
  }

  /// 可换行的说明文字。
  private func wrapping(
    _ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular
  ) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = NSFont.interface(ofSize: size, weight: weight)
    label.textColor = color
    label.preferredMaxLayoutWidth = 420
    return label
  }

  /// 来源路径：等宽、可选中、过长时截中间。
  private func pathLabel(_ path: String) -> NSTextField {
    let label = makeLabel(path, size: 11, color: SettingsTheme.ink, monospaced: true)
    label.isSelectable = true
    label.lineBreakMode = .byTruncatingMiddle
    label.toolTip = path
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  /// 风险等级的文字。
  static func riskTitle(_ risk: ToolPermissionRisk) -> String {
    switch risk {
    case .high: L("高风险")
    case .medium: L("中风险")
    case .low: L("低风险")
    }
  }

  /// POSIX 单引号转义：只含安全字符时原样显示。
  static func shellQuoted(_ argument: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
    if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// 权限风险圆点：高红、中橙、低绿。系统色自带明暗两套。
@MainActor
final class ToolRiskDotView: NSView {
  private let risk: ToolPermissionRisk

  init(risk: ToolPermissionRisk) {
    self.risk = risk
    super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 8), heightAnchor.constraint(equalToConstant: 8)])
  }

  required init?(coder: NSCoder) { nil }

  /// 风险对应的颜色。
  static func color(for risk: ToolPermissionRisk) -> NSColor {
    switch risk {
    case .high: .systemRed
    case .medium: .systemOrange
    case .low: .systemGreen
    }
  }

  /// 在当前外观下画实心圆。
  override func draw(_ dirtyRect: NSRect) {
    Self.color(for: risk).setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }
}
