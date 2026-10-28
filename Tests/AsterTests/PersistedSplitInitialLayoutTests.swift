import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 分屏视图首次布局不能给子视图「整宽 / 0」这样的中间尺寸：终端 Pane 会把它当成真实
// 窗口尺寸上报给 PTY，Claude Code 等内联 TUI 按错误宽度重画一次，再被挤回原宽度后
// 画面错乱（切回标签时工作区整树重建，每次都会经过这一步）。

/// 记录每次 `setFrameSize` 收到的尺寸，用来捕捉布局事务中途的瞬时尺寸。
@MainActor
private final class FrameRecordingView: NSView {
  var widths: [CGFloat] = []
  var heights: [CGFloat] = []

  override func setFrameSize(_ newSize: NSSize) {
    widths.append(newSize.width)
    heights.append(newSize.height)
    super.setFrameSize(newSize)
  }
}

/// 把一棵新建的分屏视图插进已经有尺寸的窗口，模拟切回标签时的重建路径。
@MainActor
private func mountFreshSplit(
  axis: SplitAxis,
  ratio: Double,
  onRatioChanged: @escaping (Double) -> Void = { _ in }
) -> (window: NSWindow, split: PersistedSplitView, first: FrameRecordingView, second: FrameRecordingView) {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
  )
  let container = NSView()
  window.contentView = container
  container.layoutSubtreeIfNeeded()

  let split = PersistedSplitView(axis: axis, ratio: ratio, onRatioChanged: onRatioChanged)
  let first = FrameRecordingView()
  let second = FrameRecordingView()
  split.addArrangedSubview(first)
  split.addArrangedSubview(second)
  split.translatesAutoresizingMaskIntoConstraints = false
  container.addSubview(split)
  NSLayoutConstraint.activate([
    split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
    split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    split.topAnchor.constraint(equalTo: container.topAnchor),
    split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
  ])
  container.layoutSubtreeIfNeeded()
  return (window, split, first, second)
}

@Test("新建的左右分屏首次布局不会把整宽交给第一个 Pane")
@MainActor
func freshHorizontalSplitNeverHandsFullWidthToFirstPane() {
  let (window, split, first, second) = mountFreshSplit(axis: .horizontal, ratio: 0.5)
  defer { window.orderOut(nil) }
  let half = (1_000 - split.dividerThickness) / 2
  #expect(abs(first.frame.width - half) <= 1, "最终宽度: \(first.frame.width)" as Comment)
  #expect(abs(second.frame.width - half) <= 1, "最终宽度: \(second.frame.width)" as Comment)
  // 只看有效尺寸：0 宽表示尚未参与布局，终端不会据此上报网格。
  for width in first.widths + second.widths where width > 1 {
    #expect(abs(width - half) <= 1, "出现瞬时宽度 \(width)，记录: \(first.widths) / \(second.widths)")
  }
}

@Test("新建的上下分屏首次布局按比例分配高度")
@MainActor
func freshVerticalSplitHonorsRatioOnFirstLayout() {
  let (window, split, first, second) = mountFreshSplit(axis: .vertical, ratio: 0.3)
  defer { window.orderOut(nil) }
  let total = (window.contentView?.bounds.height ?? 0) - split.dividerThickness
  let expectedFirst = total * 0.3
  #expect(abs(first.frame.height - expectedFirst) <= 1, "最终高度: \(first.frame.height)" as Comment)
  for height in first.heights where height > 1 {
    #expect(abs(height - expectedFirst) <= 1, "出现瞬时高度 \(height)，记录: \(first.heights)")
  }
  for height in second.heights where height > 1 {
    #expect(abs(height - (total - expectedFirst)) <= 1, "出现瞬时高度 \(height)，记录: \(second.heights)")
  }
}

@Test("按比例约束不妨碍用户拖动分隔条，拖完的比例写回并保持")
@MainActor
func ratioConstraintDoesNotBlockDividerDrag() throws {
  var reported: [Double] = []
  let (window, split, first, _) = mountFreshSplit(axis: .horizontal, ratio: 0.5) { reported.append($0) }
  defer { window.orderOut(nil) }
  let middle = split.frame.height / 2
  let start = split.convert(NSPoint(x: first.frame.maxX + split.dividerThickness / 2, y: middle), to: nil)
  let end = split.convert(NSPoint(x: 300, y: middle), to: nil)
  // NSSplitView 的拖动在 mouseDown 里自取后续事件：先把拖动与松开排进队列。
  func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }
  window.postEvent(try mouse(.leftMouseDragged, end), atStart: false)
  window.postEvent(try mouse(.leftMouseUp, end), atStart: false)
  split.mouseDown(with: try mouse(.leftMouseDown, start))
  split.layoutSubtreeIfNeeded()
  // 指针按住的是分隔条中线，拖到 x = 300 时第一个 Pane 宽 300 减半个分隔条。
  let expected = 300 - split.dividerThickness / 2
  #expect(abs(first.frame.width - expected) <= 1, "拖动后宽度: \(first.frame.width)" as Comment)
  let ratio = try #require(reported.last)
  #expect(abs(ratio - expected / (1_000 - split.dividerThickness)) < 0.005)
  // 下一轮布局（例如窗口重绘）不能把分隔条弹回旧比例。
  split.needsLayout = true
  split.layoutSubtreeIfNeeded()
  #expect(abs(first.frame.width - expected) <= 1, "重新布局后宽度: \(first.frame.width)" as Comment)
}
