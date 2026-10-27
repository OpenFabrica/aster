// Open Quickly 顶部的过滤器标签条。chip 数量、界面语言与窗口宽度都可能让一排 chip 放不下：
// 先收紧 chip 内边距与间距；仍放不下时裁掉末尾（⌘ 快捷键照样能切换），不把整列布局撑破。
import AppKit

/// 过滤器标签条：一排 `OpenQuicklyChip`，末尾一段弹性空白把 chip 推到左侧。
@MainActor
final class OpenQuicklyFilterStrip: NSStackView {
  /// 放得下时 chip 的左右内边距之和与 chip 间距。
  nonisolated static let regularPadding: CGFloat = 20
  nonisolated static let regularSpacing: CGFloat = 4
  /// 收紧后的下限；再小 chip 的边框就贴住文字了。
  nonisolated static let compactPadding: CGFloat = 10
  nonisolated static let compactSpacing: CGFloat = 2

  /// 用给定的 chip 建标签条。
  init(chips: [OpenQuicklyChip]) {
    super.init(frame: .zero)
    orientation = .horizontal
    spacing = Self.regularSpacing
    // 放不下时允许裁掉内容：默认 required 的抗裁剪会让标签条的最小宽度和整列的等宽约束打架，
    // AppKit 随便打破一条后，搜索框、结果区就不再左右对齐。
    setClippingResistancePriority(.defaultLow, for: .horizontal)
    for chip in chips { addArrangedSubview(chip) }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    addArrangedSubview(spacer)
  }

  /// 不支持从 nib 解码。
  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// 每次布局按实际宽度挑内边距与间距。宽度由外部约束决定、与 chip 无关，结果只取决于宽度和
  /// chip 文字，第二轮布局不会再改动，不会来回振荡。
  override func layout() {
    super.layout()
    fitChips(toWidth: bounds.width)
  }

  /// 把内边距与间距应用到当前的 chip 上。
  func fitChips(toWidth width: CGFloat) {
    let chips = arrangedSubviews.compactMap { $0 as? OpenQuicklyChip }
    guard !chips.isEmpty, width > 0 else { return }
    let metrics = Self.metrics(contentWidths: chips.map(\.contentWidth), available: width)
    if spacing != metrics.spacing { spacing = metrics.spacing }
    for chip in chips { chip.horizontalPadding = metrics.padding }
  }

  /// 纯计算：放得下用常规值；放不下时间距取下限，再把可用宽度平均分给各 chip 的内边距，
  /// 不低于下限也不高于常规值。间距按 chip 个数计（最后一个 chip 与弹性空白之间也有一个）。
  nonisolated static func metrics(contentWidths: [CGFloat], available: CGFloat) -> (padding: CGFloat, spacing: CGFloat) {
    let count = CGFloat(contentWidths.count)
    guard count > 0 else { return (regularPadding, regularSpacing) }
    let content = contentWidths.reduce(0, +)
    if content + count * (regularPadding + regularSpacing) <= available {
      return (regularPadding, regularSpacing)
    }
    let padding = floor((available - content - count * compactSpacing) / count)
    return (min(regularPadding, max(compactPadding, padding)), compactSpacing)
  }
}
