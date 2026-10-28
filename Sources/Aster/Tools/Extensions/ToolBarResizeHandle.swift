// 状态条边缘的拖高把手：约 4pt 的命中带，悬停显示上下调整光标，拖动按位移回调，双击请求恢复单行。
// 底部类条的把手在上边缘（往上拖变高），`tab.top` 在下边缘（往下拖变高）。高度换算与吸附由 ToolBarView 负责。
import AppKit
import AsterCore

/// 拖高把手。只在主线程使用。
@MainActor
final class ToolBarResizeHandle: NSView {
  /// 把手贴在条的哪条边上。
  enum Edge {
    case top
    case bottom
  }

  let edge: Edge
  /// 开始拖动。
  var onDragBegan: (() -> Void)?
  /// 拖动中：相对按下点的位移（点），正值表示条要变高。
  var onDrag: ((CGFloat) -> Void)?
  /// 松开。
  var onDragEnded: (() -> Void)?
  /// 双击：恢复单行。
  var onReset: (() -> Void)?
  /// 悬停或拖动状态变了：条据此把边线换成强调色。
  var onHighlightChange: ((Bool) -> Void)?

  private var dragStartY: CGFloat?
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false {
    didSet { if isHovering != oldValue { notifyHighlight() } }
  }

  /// 悬停或拖动中。
  var isHighlighted: Bool { isHovering || dragStartY != nil }

  /// `edge` 决定拖动方向。
  init(edge: Edge) {
    self.edge = edge
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.splitter)
    setAccessibilityLabel(L("调整状态条高度"))
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 拖动把手不应带着窗口走（`window.top` 不可拖高，这里总是 false）。
  override var mouseDownCanMoveWindow: Bool { false }

  /// 窗口不在前台时第一下也能直接拖，与 Panel divider 一致。
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeUpDown)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
  }

  /// 双击恢复单行；单击开始拖动，记下按下点的窗口纵坐标。
  override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2 {
      onReset?()
      return
    }
    dragStartY = event.locationInWindow.y
    notifyHighlight()
    onDragBegan?()
  }

  /// 窗口坐标 y 向上：上边缘把手往上拖（y 变大）变高，下边缘把手往下拖变高。
  /// 拖出命中带后光标矩形不再生效，这里每次都重新设一次光标。
  override func mouseDragged(with event: NSEvent) {
    guard let dragStartY else { return }
    NSCursor.resizeUpDown.set()
    let delta = event.locationInWindow.y - dragStartY
    onDrag?(edge == .top ? delta : -delta)
  }

  /// 松开结束拖动；只有真的开始过拖动才回调（双击的第二下不算）。
  override func mouseUp(with event: NSEvent) {
    guard dragStartY != nil else { return }
    dragStartY = nil
    notifyHighlight()
    onDragEnded?()
  }

  /// 把当前高亮状态告诉条。
  private func notifyHighlight() {
    onHighlightChange?(isHighlighted)
  }
}
