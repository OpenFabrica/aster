// 便笺的窗口类型与外观：快捷键优先的窗口、纯色块视图与纸面配色。
import AppKit
import AsterCore

/// 便笺窗口：便笺的快捷键（`⌘N`、`⌘B`、`⌘1`–`⌘6` 等）先于菜单处理，不会落到工作区的同名菜单
/// （新建窗口、新建标签、切换标签）。双击标题栏折叠而不是缩放。
@MainActor
final class StickyNoteWindow: ToolStandaloneWindow {
  var onCommand: ((StickyNoteCommand) -> Void)?
  var onToggleCollapse: (() -> Void)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let onCommand,
      let command = StickyNoteCommand.command(
        characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
    {
      onCommand(command)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// 双击标题栏（系统设置为「缩放」时）：折叠或展开。
  override func zoom(_ sender: Any?) { onToggleCollapse?() }

  /// 同上，覆盖经菜单或按钮触发的缩放。
  override func performZoom(_ sender: Any?) { onToggleCollapse?() }

  /// 双击标题栏（系统设置为「最小化」时）与 `⌘M`：便笺不进程序坞，改为折叠或展开。
  override func performMiniaturize(_ sender: Any?) { onToggleCollapse?() }
}

/// 纯色块：纸面与顶部色带（比纸面略深，当作标题栏，点在这里可以拖动窗口）。
@MainActor
final class StickyNoteFillView: NSView {
  var color: NSColor = .clear {
    didSet { needsDisplay = true }
  }

  override var mouseDownCanMoveWindow: Bool { true }

  /// 只填自己的范围：macOS 14 起视图默认不裁剪，`dirtyRect` 可能超出 bounds，直接填会盖住兄弟视图。
  override func draw(_ dirtyRect: NSRect) {
    color.setFill()
    bounds.intersection(dirtyRect).fill()
  }
}

/// 便笺的颜色：纸面、色带、名字与菜单色块。纸面取 macOS「便笺」的经典配色。
@MainActor
enum StickyNotePalette {
  /// 纸面颜色。
  static func paper(_ color: StickyNoteColor) -> NSColor {
    let hex: UInt32 =
      switch color {
      case .yellow: 0xFFF9A6
      case .blue: 0xADF4FF
      case .green: 0xB2FFA1
      case .pink: 0xFFC7C7
      case .purple: 0xD6CCFF
      case .gray: 0xEEEEEE
      }
    return NSColor(
      srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }

  /// 顶部色带：纸面压暗一点。
  static func strip(_ color: StickyNoteColor) -> NSColor {
    paper(color).blended(withFraction: 0.05, of: .black) ?? paper(color)
  }

  /// 菜单里显示的名字。
  static func name(_ color: StickyNoteColor) -> String {
    switch color {
    case .yellow: L("黄色")
    case .blue: L("蓝色")
    case .green: L("绿色")
    case .pink: L("粉色")
    case .purple: L("紫色")
    case .gray: L("灰色")
    }
  }

  /// 菜单与列表用的小圆色块。
  static func swatch(_ color: StickyNoteColor, diameter: CGFloat = 12) -> NSImage {
    let paperColor = paper(color)
    let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
      let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
      paperColor.setFill()
      path.fill()
      NSColor(white: 0, alpha: 0.25).setStroke()
      path.lineWidth = 1
      path.stroke()
      return true
    }
    image.isTemplate = false
    return image
  }
}
