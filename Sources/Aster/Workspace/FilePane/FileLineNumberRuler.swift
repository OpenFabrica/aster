// 源码逻辑行号：独立于文本内容，换行折行不产生额外行号。
import AppKit

@MainActor
final class FileLineNumberRuler: NSRulerView {
  private weak var textView: NSTextView?
  private var lineStarts = [0]
  private var observers: [NSObjectProtocol] = []

  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    identifier = NSUserInterfaceItemIdentifier("file-pane-line-numbers")
    scrollView.contentView.postsBoundsChangedNotifications = true
    for (name, object) in [
      (NSTextStorage.didProcessEditingNotification, textView.textStorage as AnyObject?),
      (NSView.boundsDidChangeNotification, scrollView.contentView as AnyObject?),
    ] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
        [weak self] notification in
        let textChanged = notification.name == NSTextStorage.didProcessEditingNotification
        MainActor.assumeIsolated {
          guard let self else { return }
          if textChanged,
            self.textView?.textStorage?.editedMask.contains(.editedCharacters) == true {
            self.updateLineStarts()
          }
          self.needsDisplay = true
        }
      })
    }
    updateLineStarts()
  }

  required init(coder: NSCoder) { super.init(coder: coder) }
  override var isFlipped: Bool { true }

  isolated deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular) }

  private func updateLineStarts() {
    let text = (textView?.string ?? "") as NSString
    lineStarts = [0]
    var cursor = 0
    while cursor < text.length {
      let end = NSMaxRange(text.lineRange(for: NSRange(location: cursor, length: 0)))
      if end < text.length || (end == text.length && text.substring(with: NSRange(location: end - 1, length: 1)).rangeOfCharacter(from: .newlines) != nil) {
        lineStarts.append(end)
      }
      cursor = end
    }
    ruleThickness = max(36, (String(lineStarts.count) as NSString).size(withAttributes: [.font: numberFont]).width + 16)
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
    textView.backgroundColor.setFill()
    bounds.fill()
    let visible = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    // 二分定位可见逻辑行，滚动时只绘制视口附近的行号。
    var lower = 0
    var upper = lineStarts.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if lineStarts[middle] < characters.location { lower = middle + 1 } else { upper = middle }
    }
    var index = max(0, lower - 1)
    while index < lineStarts.count, lineStarts[index] <= NSMaxRange(characters) {
      let offset = lineStarts[index]
      let lineRect: NSRect
      if offset == (textView.string as NSString).length {
        lineRect = layout.extraLineFragmentRect
      } else {
        lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
      }
      let position = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y), from: textView)
      let label = String(index + 1) as NSString
      let attributes: [NSAttributedString.Key: Any] = [.font: numberFont,
        .foregroundColor: textView.textColor?.withAlphaComponent(0.5) ?? AsterTheme.secondaryInk]
      label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 8,
        y: position.y + max(0, (lineRect.height - numberFont.ascender + numberFont.descender) / 2)), withAttributes: attributes)
      index += 1
    }
  }
}
