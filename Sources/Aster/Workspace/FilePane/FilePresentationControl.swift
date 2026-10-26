// 文件模式开关：保留原生分段控件语义，用圆形滑块展示当前状态图标。
import AppKit

@MainActor
final class FilePresentationControl: NSSegmentedControl {
  override var selectedSegment: Int { didSet { needsDisplay = true } }
  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
    let selected = max(0, min(1, selectedSegment))
    let thumb = NSRect(x: selected == 0 ? 2 : bounds.width - 20,
      y: bounds.midY - 9, width: 18, height: 18)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 1
    shadow.shadowOffset = NSSize(width: 0, height: -0.5)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: thumb).fill()
    NSGraphicsContext.restoreGraphicsState()
    // 滑块始终是白色，图标使用浅色控件的系统 label 色，保持深色外观下的对比度。
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
      image(forSegment: selected)?.withSymbolConfiguration(
        .init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.labelColor])))?
        .draw(in: thumb.insetBy(dx: 3.5, dy: 3.5))
    }
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
      outline.lineWidth = 1
      outline.stroke()
    }
  }

  override func mouseDown(with event: NSEvent) { selectMode(selectedSegment == 0 ? 1 : 0) }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 49, 36: selectMode(selectedSegment == 0 ? 1 : 0)
    case 123: selectMode(0)
    case 124: selectMode(1)
    default: super.keyDown(with: event)
    }
  }

  private func selectMode(_ segment: Int) {
    guard isEnabled else { return }
    selectedSegment = segment
    if let action { NSApp.sendAction(action, to: target, from: self) }
  }
}
