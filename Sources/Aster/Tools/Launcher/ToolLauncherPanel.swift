// 工具面板的窗口：无边框、非激活的浮动 NSPanel。放开 key、挡住 main，Esc 兜底交给控制器，
// 并在没有标题栏的情况下按内容区指定的把手拖动窗口。窗口策略在 ToolLauncherController。
import AppKit

/// 无边框面板默认不能成为 key；这里放开，搜索框才能接收输入。不成为 main，不抢工作区窗口的主窗口身份。
/// 无边框也没有标题栏可拖，按在内容区指定的把手上时由这里拖动窗口。
@MainActor
final class ToolLauncherPanel: NSPanel {
  /// `cancelOperation`（Esc）兜底。
  var onCancel: (() -> Void)?
  /// 判断鼠标按下的视图是不是拖动把手。
  var isDragHandle: ((NSView) -> Bool)?
  /// 一次拖动结束，面板可能换了位置。
  var onDidDrag: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  /// Esc 兜底，交给控制器处理。
  override func cancelOperation(_ sender: Any?) { onCancel?() }

  /// 左键按在把手上就拖动面板。`performDrag` 跑系统的窗口拖动（贴边吸附与普通窗口一致），松开鼠标才返回。
  /// 挂着 sheet 时不拖，免得 sheet 与面板错位。
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, attachedSheet == nil, let contentView,
      let hit = contentView.hitTest(
        contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
      isDragHandle?(hit) == true
    {
      if !isKeyWindow { makeKey() }
      performDrag(with: event)
      onDidDrag?()
      return
    }
    super.sendEvent(event)
  }
}
