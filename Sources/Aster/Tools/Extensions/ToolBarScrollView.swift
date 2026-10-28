// 状态条的滚动容器与内容层：单行放不下时左右滚动（滚轮的纵向输入转成横向），拉高成多行后内容超出时上下滚动。
// 滚动条固定 overlay 样式，「始终显示滚动条」的系统设置下也不会挤占 22–28pt 的条高。条本体与排版在 ToolBarView.swift。
import AppKit

/// 条的滚动视图。只在主线程使用。
@MainActor
final class ToolBarScrollView: NSScrollView {
  /// 单行模式：纵向滚轮转成横向滚动。
  var convertsVerticalWheel = true

  /// 透明、无边框、按需显示滚动条。
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    borderType = .noBorder
    autohidesScrollers = true
    hasHorizontalScroller = true
    hasVerticalScroller = true
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .none
    contentView.drawsBackground = false
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 始终 overlay：legacy 滚动条会占掉 15pt，把单行条整个盖住。
  override var scrollerStyle: NSScroller.Style {
    get { .overlay }
    set { super.scrollerStyle = .overlay }
  }

  /// 鼠标滚轮只有纵向：单行条横向放不下时把纵向增量换成横向；触控板横扫与其它情况照常交给系统。
  override func scrollWheel(with event: NSEvent) {
    guard convertsVerticalWheel, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), canScrollHorizontally
    else { return super.scrollWheel(with: event) }
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * horizontalLineScroll
    scrollHorizontally(by: delta)
  }

  /// 内容比可见区宽。
  var canScrollHorizontally: Bool {
    (documentView?.frame.width ?? 0) > contentView.bounds.width + 0.5
  }

  /// 内容比可见区高。
  var canScrollVertically: Bool {
    (documentView?.frame.height ?? 0) > contentView.bounds.height + 0.5
  }

  /// 横向滚动 `delta` 点（正值向左，即看前面的项目，与纵向滚轮「向上」同向），夹在内容范围内。
  func scrollHorizontally(by delta: CGFloat) {
    let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
    var origin = contentView.bounds.origin
    origin.x = min(max(0, origin.x - delta), maxX)
    contentView.scroll(to: origin)
    reflectScrolledClipView(contentView)
  }
}

/// 条的内容层（滚动视图的 documentView）：按钮、spinner 与段间分隔线都在这里，跟着内容一起滚。
/// 翻转坐标，第 0 行在最上面。空白处的点击交回条本体，`window.top` 的拖窗 / 双击缩放因此不变。
@MainActor
final class ToolBarContentView: NSView {
  weak var owner: ToolBarView?

  override var isFlipped: Bool { true }

  /// 空白处是否能拖动窗口，跟条本体一致。
  override var mouseDownCanMoveWindow: Bool { owner?.isWindowDragRegion ?? false }

  /// 空白处的点击交给条本体处理（拖窗 / 双击缩放）。
  override func mouseDown(with event: NSEvent) {
    guard let owner else { return super.mouseDown(with: event) }
    owner.mouseDown(with: event)
  }
}
