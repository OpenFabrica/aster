// Open Quickly 过滤器标签条：加了「工具」chip 后，长语言（日 / 德 / 法）与窄窗口下先收紧再裁剪，不撑破整列。
import AppKit
import Testing

@testable import Aster

@Test("标签条间距规则：放得下用常规值，放不下先压间距、再平均压内边距，不低于下限")
func openQuicklyFilterStripMetrics() {
  let widths = [CGFloat](repeating: 40, count: 10)
  // 10 × (40 + 20 + 4) = 640，放得下。
  #expect(OpenQuicklyFilterStrip.metrics(contentWidths: widths, available: 640) == (20, 4))
  // 600 - 400 - 10 × 2 = 180 → 每个 chip 18。
  #expect(OpenQuicklyFilterStrip.metrics(contentWidths: widths, available: 600) == (18, 2))
  // 再窄也不低于 10，剩下的交给裁剪。
  #expect(OpenQuicklyFilterStrip.metrics(contentWidths: widths, available: 300) == (10, 2))
  #expect(OpenQuicklyFilterStrip.metrics(contentWidths: [], available: 300) == (20, 4))
}

/// 一组德语长度的 chip。
@MainActor
private func longChips() -> [OpenQuicklyChip] {
  ["Alle", "Arbeitsbereiche", "Geöffnet", "Zuletzt", "Ordner", "SSH", "Agenten", "Aktuell", "Recipes",
    "Werkzeuge", "Dateien"].map { OpenQuicklyChip(title: $0, commandHint: "⌘K") {} }
}

/// 把标签条放进给定宽度的容器并完成布局。
@MainActor
private func layOut(_ strip: OpenQuicklyFilterStrip, width: CGFloat) -> NSView {
  let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
  container.addSubview(strip)
  strip.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
    strip.topAnchor.constraint(equalTo: container.topAnchor),
    strip.widthAnchor.constraint(equalTo: container.widthAnchor),
  ])
  container.layoutSubtreeIfNeeded()
  container.layoutSubtreeIfNeeded()
  return container
}

@MainActor
@Test("长语言下标签条收紧 chip 后全部放进 672pt，窄窗口里只裁剪、宽度仍服从外部约束")
func openQuicklyFilterStripFitsLongTitles() {
  let chips = longChips()
  let natural = chips.reduce(CGFloat(0)) { $0 + $1.contentWidth + 24 }
  #expect(natural > 672)

  let strip = OpenQuicklyFilterStrip(chips: chips)
  _ = layOut(strip, width: 672)
  #expect(abs(strip.frame.width - 672) < 0.5)
  #expect(chips.allSatisfy { $0.horizontalPadding < OpenQuicklyFilterStrip.regularPadding })
  #expect(chips.allSatisfy { $0.frame.maxX <= strip.bounds.maxX + 0.5 })
  // 相邻 chip 不重叠。
  for (left, right) in zip(chips, chips.dropFirst()) {
    #expect(left.frame.maxX <= right.frame.minX + 0.5)
  }

  let narrowChips = longChips()
  let narrow = OpenQuicklyFilterStrip(chips: narrowChips)
  _ = layOut(narrow, width: 320)
  #expect(abs(narrow.frame.width - 320) < 0.5)
  #expect(narrowChips.allSatisfy { $0.horizontalPadding == OpenQuicklyFilterStrip.compactPadding })
}
