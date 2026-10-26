// Chat 消息与备注的文本滚动区：约束完成后用真实 viewport 建立可见文本容器。
import AppKit

@MainActor
final class AgentChatTextScrollView: NSScrollView {
  init(textView: NSTextView) {
    super.init(frame: .zero)
    hasVerticalScroller = true
    autohidesScrollers = true
    borderType = .bezelBorder
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.autoresizingMask = .width
    textView.textContainer?.widthTracksTextView = true
    documentView = textView
  }

  required init?(coder: NSCoder) { nil }

  override func tile() {
    super.tile()
    guard let text = documentView as? NSTextView, contentSize.width > 0, contentSize.height > 0 else { return }
    text.minSize = contentSize
    text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height)))
    text.textContainer?.containerSize = NSSize(
      width: max(0, contentSize.width - text.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
  }
}
