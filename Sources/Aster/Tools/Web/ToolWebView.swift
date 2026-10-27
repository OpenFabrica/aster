// 网页工具专用的 WKWebView：记下用户最近一次在页面里点击或按键的时间，导航策略据此区分用户点击与脚本跳转。
import AppKit
import WebKit

/// 记录用户输入时间的 WKWebView。只增加记录，不改变任何事件的处理。
@MainActor
final class ToolWebView: WKWebView {
  /// 最近一次用户输入的时间戳（与 `NSEvent.timestamp` 同一时钟，即系统启动以来的秒数）。
  private(set) var lastUserInputTime: TimeInterval = -.infinity

  /// 鼠标按下：记录后交给 WebKit。
  override func mouseDown(with event: NSEvent) {
    lastUserInputTime = event.timestamp
    super.mouseDown(with: event)
  }

  /// 鼠标抬起（点击在这里完成）：记录后交给 WebKit。
  override func mouseUp(with event: NSEvent) {
    lastUserInputTime = event.timestamp
    super.mouseUp(with: event)
  }

  /// 中键抬起（中键点链接）：记录后交给 WebKit。
  override func otherMouseUp(with event: NSEvent) {
    lastUserInputTime = event.timestamp
    super.otherMouseUp(with: event)
  }

  /// 按键（回车激活聚焦的链接）：记录后交给 WebKit。
  override func keyDown(with event: NSEvent) {
    lastUserInputTime = event.timestamp
    super.keyDown(with: event)
  }

  /// 最近 `interval` 秒内是否有过用户输入。
  func hasRecentUserInput(
    within interval: TimeInterval = WebToolNavigationPolicy.userInputGracePeriod,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    now - lastUserInputTime <= interval
  }
}
