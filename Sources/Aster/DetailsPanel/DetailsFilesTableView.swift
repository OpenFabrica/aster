// 右侧 Files 页的表格：yazi 式键盘浏览（j/k、h/l、Enter、/、.、Esc）与选中行外观。
// 按键只翻译成命令交给详情面板；树结构和预览策略留在控制器与预览协调器里。
import AppKit

/// Files 表格能识别的键盘命令。↑/↓、Home/End、PageUp/PageDown 走 NSTableView 原生行为。
enum DetailsFilesKeyCommand: Equatable {
  case moveUp
  case moveDown
  /// → / l：展开目录；已展开时进入第一个子项。
  case expandOrDescend
  /// ← / h：折叠已展开的目录；否则跳到父目录行。
  case collapseOrAscend
  /// Return / Enter：固定预览（打开文件），目录则展开或折叠。
  case activate
  /// Space：展开或折叠目录；文件上无动作，但吞掉按键避免系统提示音。
  case toggleDirectory
  /// `/`：聚焦 Find 搜索框。
  case focusFind
  /// `.`：切换是否显示隐藏项。
  case toggleHidden
  /// Esc：把键盘焦点还给活动 Pane。
  case returnFocus

  /// 把一次按键翻译成命令。带 ⌘ / ⌃ / ⌥ 的组合键一律不拦截，交给菜单与系统快捷键。
  static func command(
    characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
  ) -> DetailsFilesKeyCommand? {
    let relevant = modifiers.intersection([.command, .control, .option])
    guard relevant.isEmpty else { return nil }
    switch keyCode {
    case 123: return .collapseOrAscend  // ←
    case 124: return .expandOrDescend  // →
    case 36, 76: return .activate  // Return、小键盘 Enter
    case 49: return .toggleDirectory  // Space
    case 53: return .returnFocus  // Esc
    default: break
    }
    switch characters {
    case "j": return .moveDown
    case "k": return .moveUp
    case "l": return .expandOrDescend
    case "h": return .collapseOrAscend
    case "/": return .focusFind
    case ".": return .toggleHidden
    default: return nil
    }
  }
}

/// Files 树里一行的导航所需信息；与 AppKit 行视图解耦，便于单独测试。
struct DetailsFilesNavigationRow: Equatable {
  let path: String
  let depth: Int
  /// 可在树内展开（真实目录，不含指向目录的符号链接）。
  let isExpandable: Bool
  let isExpanded: Bool
}

/// 键盘命令落到树上的结果。
enum DetailsFilesNavigationAction: Equatable {
  case select(Int)
  case expand(String)
  case collapse(String)
  case none
}

/// 纯函数：根据当前行与选中位置计算移动、展开或折叠。
enum DetailsFilesNavigation {
  static func resolve(
    rows: [DetailsFilesNavigationRow], selected: Int?, command: DetailsFilesKeyCommand
  ) -> DetailsFilesNavigationAction {
    guard !rows.isEmpty else { return .none }
    guard let selected, rows.indices.contains(selected) else {
      // 没有选中行时，任何移动类命令都先落到第一行，和 yazi 打开目录时光标在首行一致。
      switch command {
      case .moveUp, .moveDown, .expandOrDescend, .collapseOrAscend: return .select(0)
      default: return .none
      }
    }
    let row = rows[selected]
    switch command {
    case .moveDown:
      return selected + 1 < rows.count ? .select(selected + 1) : .none
    case .moveUp:
      return selected > 0 ? .select(selected - 1) : .none
    case .expandOrDescend:
      guard row.isExpandable else { return .none }
      guard row.isExpanded else { return .expand(row.path) }
      // 已展开：下一行更深才是它的子项；空目录展开后没有子项，停在原地。
      let next = selected + 1
      return rows.indices.contains(next) && rows[next].depth > row.depth ? .select(next) : .none
    case .collapseOrAscend:
      if row.isExpandable, row.isExpanded { return .collapse(row.path) }
      guard row.depth > 0 else { return .none }
      // 父目录是往上第一个深度小一级的行；树按遍历顺序压平，所以一定在上方。
      var index = selected - 1
      while index >= 0 {
        if rows[index].depth == row.depth - 1 { return .select(index) }
        index -= 1
      }
      return .none
    case .toggleDirectory:
      guard row.isExpandable else { return .none }
      return row.isExpanded ? .collapse(row.path) : .expand(row.path)
    case .activate, .focusFind, .toggleHidden, .returnFocus:
      return .none
    }
  }
}

/// Files 页专用表格：关闭输入即跳转（type-select 会和 j/k/h/l 抢键），按键先交给 `onCommand`。
@MainActor
final class DetailsFilesTableView: NSTableView {
  /// 返回 true 表示命令已处理；false 时按键交还 NSTableView 默认行为。
  var onCommand: ((DetailsFilesKeyCommand) -> Bool)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    allowsTypeSelect = false
  }

  required init?(coder: NSCoder) { nil }

  override func keyDown(with event: NSEvent) {
    if let command = DetailsFilesKeyCommand.command(
      characters: event.charactersIgnoringModifiers,
      keyCode: event.keyCode,
      modifiers: event.modifierFlags
    ), onCommand?(command) == true {
      return
    }
    super.keyDown(with: event)
  }
}

/// Files 选中行：圆角底色。表格有焦点时用强调色，失焦时用淡色，和 Finder 侧栏一致。
@MainActor
final class DetailsFilesSelectionRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }
    let color = isEmphasized
      ? AsterTheme.accent.withAlphaComponent(0.22)
      : AsterTheme.ink.withAlphaComponent(0.08)
    color.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
  }

  /// 选中底色很浅，文字保持正常配色，不切换成反白。
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
