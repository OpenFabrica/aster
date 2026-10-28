// 便笺的命令与文字格式：按键到命令的映射（与 macOS「便笺」一致）、粗体 / 斜体切换与字号增减。
// 命令映射是纯函数，便于测试；格式操作走 NSTextView 的改动流程，可以撤销。
import AppKit
import AsterCore

/// 便笺窗口里的命令。快捷键与 macOS「便笺」一致。
enum StickyNoteCommand: Equatable {
  /// 新建便笺（`⌘N`）。
  case newNote
  /// 显示字体面板（`⌘T`）。
  case showFonts
  /// 粗体（`⌘B`）。
  case bold
  /// 斜体（`⌘I`）。
  case italic
  /// 下划线（`⌘U`）。
  case underline
  /// 放大（`⌘+`）。
  case bigger
  /// 缩小（`⌘-`）。
  case smaller
  /// 换纸面颜色（`⌘1`–`⌘6`，按 `StickyNoteColor.allCases` 的顺序）。
  case color(StickyNoteColor)
  /// 浮在最前面（`⌥⌘F`）。
  case floatOnTop
  /// 半透明（`⌥⌘T`）。
  case translucent

  /// 把按键翻译成命令；不是便笺的快捷键时返回 nil，交给菜单与正文照常处理。
  /// `⌘+` 在美式键盘上是 `⇧⌘=`，`⌘=` 也算放大，和系统的「放大」一致。
  static func command(characters: String?, modifiers: NSEvent.ModifierFlags) -> StickyNoteCommand? {
    let flags = modifiers.intersection([.command, .option, .control, .shift])
    guard let key = characters?.lowercased(), !key.isEmpty else { return nil }
    switch flags {
    case .command:
      switch key {
      case "n": return .newNote
      case "t": return .showFonts
      case "b": return .bold
      case "i": return .italic
      case "u": return .underline
      case "=", "+": return .bigger
      case "-": return .smaller
      default:
        guard let digit = key.first?.wholeNumberValue, (1...StickyNoteColor.allCases.count).contains(digit) else {
          return nil
        }
        return .color(StickyNoteColor.allCases[digit - 1])
      }
    case [.command, .shift]:
      return key == "+" || key == "=" ? .bigger : nil
    case [.command, .option]:
      switch key {
      case "f": return .floatOnTop
      case "t": return .translucent
      default: return nil
      }
    default:
      return nil
    }
  }

  /// 菜单里显示的快捷键（按键与修饰键）。
  var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
    switch self {
    case .newNote: ("n", .command)
    case .showFonts: ("t", .command)
    case .bold: ("b", .command)
    case .italic: ("i", .command)
    case .underline: ("u", .command)
    case .bigger: ("+", .command)
    case .smaller: ("-", .command)
    case .color(let color): (String((StickyNoteColor.allCases.firstIndex(of: color) ?? 0) + 1), .command)
    case .floatOnTop: ("f", [.command, .option])
    case .translucent: ("t", [.command, .option])
    }
  }
}

/// 便笺正文的格式操作。有选区时改选区，没有选区时改接下来输入的文字。
@MainActor
enum StickyNoteFormatter {
  /// 字号范围（点）。
  static let sizeRange: ClosedRange<CGFloat> = 8...96

  /// 粗体或斜体：选区开头已经有这个特征就整段去掉，否则整段加上（与「便笺」「文本编辑」一致）。
  static func toggle(_ trait: NSFontTraitMask, in textView: NSTextView) {
    let manager = NSFontManager.shared
    let hasTrait = manager.traits(of: leadingFont(in: textView)).contains(trait)
    apply(in: textView) { font in
      hasTrait ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
    }
  }

  /// 字号加减 `delta` 点，限制在 `sizeRange` 内。
  static func adjustSize(by delta: CGFloat, in textView: NSTextView) {
    apply(in: textView) { font in
      let size = min(max(font.pointSize + delta, sizeRange.lowerBound), sizeRange.upperBound)
      return NSFontManager.shared.convert(font, toSize: size)
    }
  }

  /// 选区开头（没有选区时是输入属性）的字体，决定切换方向。
  private static func leadingFont(in textView: NSTextView) -> NSFont {
    let fallback = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    guard let range = selectedRanges(in: textView).first, let storage = textView.textStorage else {
      return textView.typingAttributes[.font] as? NSFont ?? fallback
    }
    return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? fallback
  }

  /// 非空选区。
  private static func selectedRanges(in textView: NSTextView) -> [NSRange] {
    textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
  }

  /// 把字体变换用到选区里每一段字体上；没有选区时只改输入属性。经 shouldChangeText / didChangeText，
  /// 这样能撤销，也会发出正文变化让便笺保存。
  private static func apply(in textView: NSTextView, _ transform: (NSFont) -> NSFont) {
    let fallback = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let ranges = selectedRanges(in: textView)
    guard !ranges.isEmpty, let storage = textView.textStorage else {
      var attributes = textView.typingAttributes
      attributes[.font] = transform(attributes[.font] as? NSFont ?? fallback)
      textView.typingAttributes = attributes
      return
    }
    guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else {
      return
    }
    storage.beginEditing()
    for range in ranges {
      storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
        storage.addAttribute(.font, value: transform(value as? NSFont ?? fallback), range: subrange)
      }
    }
    storage.endEditing()
    textView.didChangeText()
  }
}
