// 受管终端创建或恢复期间的等待提示，随显示桥挂载自动移除。
import AppKit
import AsterCore

@MainActor
final class ManagedTerminalLoadingView: NSView {
  private let spinner = NSProgressIndicator()

  init(restoring: Bool) {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("terminal-managed-loading")
    let title = restoring ? L("正在恢复终端…") : L("正在启动终端…")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(title)

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isIndeterminate = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimation(nil)
    let label = NSTextField(labelWithString: title)
    label.font = .interface(ofSize: 12)
    label.textColor = AsterTheme.secondaryInk
    let row = NSStackView(views: [spinner, label])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      spinner.widthAnchor.constraint(equalToConstant: 16),
      spinner.heightAnchor.constraint(equalToConstant: 16),
      row.centerXAnchor.constraint(equalTo: centerXAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 同一容器反复刷新时保持唯一提示，避免叠加动画或重置转圈。
  static func show(in host: NSView, restoring: Bool) {
    guard !host.subviews.contains(where: { $0 is ManagedTerminalLoadingView }) else { return }
    let status = ManagedTerminalLoadingView(restoring: restoring)
    host.addSubview(status)
    status.pinEdges(to: host)
  }

  static func remove(from host: NSView?) {
    for case let status as ManagedTerminalLoadingView in host?.subviews ?? [] {
      status.spinner.stopAnimation(nil)
      status.removeFromSuperview()
    }
  }
}
