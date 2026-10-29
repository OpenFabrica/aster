// Files 表格的 yazi 式按键映射与树导航纯函数。
import AppKit
import Testing

@testable import Aster

/// 按真实键码翻译一次无修饰键的按键。
private func command(
  _ characters: String?, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []
) -> DetailsFilesKeyCommand? {
  DetailsFilesKeyCommand.command(characters: characters, keyCode: keyCode, modifiers: modifiers)
}

/// 导航夹具：a（展开）/x、a/sub（折叠）、empty（展开但无子项）、z 文件。
private let navigationRows: [DetailsFilesNavigationRow] = [
  .init(path: "/r/a", depth: 0, isExpandable: true, isExpanded: true),
  .init(path: "/r/a/x", depth: 1, isExpandable: false, isExpanded: false),
  .init(path: "/r/a/sub", depth: 1, isExpandable: true, isExpanded: false),
  .init(path: "/r/empty", depth: 0, isExpandable: true, isExpanded: true),
  .init(path: "/r/z", depth: 0, isExpandable: false, isExpanded: false),
]

/// 在导航夹具上解析一次命令。
private func resolve(_ selected: Int?, _ command: DetailsFilesKeyCommand) -> DetailsFilesNavigationAction {
  DetailsFilesNavigation.resolve(rows: navigationRows, selected: selected, command: command)
}

@Test("Files 按键映射覆盖 yazi 常用键")
func filesKeyMappingCoversYaziKeys() {
  #expect(command("j", 38) == .moveDown)
  #expect(command("k", 40) == .moveUp)
  #expect(command("h", 4) == .collapseOrAscend)
  #expect(command("l", 37) == .expandOrDescend)
  #expect(command(nil, 123) == .collapseOrAscend)
  #expect(command(nil, 124) == .expandOrDescend)
  #expect(command("\r", 36) == .activate)
  #expect(command("\u{3}", 76) == .activate)
  #expect(command(" ", 49) == .toggleDirectory)
  #expect(command("\u{1b}", 53) == .returnFocus)
  #expect(command("/", 44) == .focusFind)
  #expect(command(".", 47) == .toggleHidden)
  #expect(command("x", 7) == nil)
  // ↑/↓ 交给 NSTableView 原生选择，不在这里拦截。
  #expect(command(nil, 125) == nil)
  #expect(command(nil, 126) == nil)
}

@Test("方向键自带的 function / numericPad 标志不影响映射")
func filesArrowKeysIgnoreFunctionFlags() {
  #expect(command(nil, 124, [.function, .numericPad]) == .expandOrDescend)
  #expect(command(nil, 123, [.function, .numericPad, .shift]) == .collapseOrAscend)
}

@Test(
  "带 ⌘ / ⌃ / ⌥ 的组合键一律不拦截",
  arguments: [NSEvent.ModifierFlags.command, .control, .option, [.command, .shift], [.control, .option]])
func filesKeyMappingSkipsMenuModifiers(modifiers: NSEvent.ModifierFlags) {
  let keys: [(String?, UInt16)] = [
    ("j", 38), ("k", 40), ("h", 4), ("l", 37), (nil, 123), (nil, 124),
    ("\r", 36), (" ", 49), ("\u{1b}", 53), ("/", 44), (".", 47),
  ]
  for (characters, keyCode) in keys {
    #expect(command(characters, keyCode, modifiers) == nil)
  }
}

@Test("Files 表格关闭输入即跳转，避免和 j/k/h/l 抢键")
@MainActor
func filesTableDisablesTypeSelect() {
  #expect(DetailsFilesTableView().allowsTypeSelect == false)
}

@Test("→ 展开折叠目录，已展开时进入第一个子项，空目录停住")
func filesNavigationExpandOrDescend() {
  #expect(resolve(2, .expandOrDescend) == .expand("/r/a/sub"))
  #expect(resolve(0, .expandOrDescend) == .select(1))
  #expect(resolve(3, .expandOrDescend) == .none)
  #expect(resolve(4, .expandOrDescend) == .none)
  #expect(resolve(1, .expandOrDescend) == .none)
}

@Test("← 折叠已展开目录，否则跳到父目录行，顶层停住")
func filesNavigationCollapseOrAscend() {
  #expect(resolve(0, .collapseOrAscend) == .collapse("/r/a"))
  #expect(resolve(3, .collapseOrAscend) == .collapse("/r/empty"))
  #expect(resolve(1, .collapseOrAscend) == .select(0))
  #expect(resolve(2, .collapseOrAscend) == .select(0))
  #expect(resolve(4, .collapseOrAscend) == .none)
}

@Test("没有选中行时移动类命令先落到第一行")
func filesNavigationWithoutSelectionSelectsFirstRow() {
  for move in [DetailsFilesKeyCommand.moveDown, .moveUp, .expandOrDescend, .collapseOrAscend] {
    #expect(resolve(nil, move) == .select(0))
    #expect(resolve(99, move) == .select(0))
  }
  #expect(resolve(nil, .activate) == .none)
  #expect(resolve(nil, .toggleDirectory) == .none)
  #expect(DetailsFilesNavigation.resolve(rows: [], selected: nil, command: .moveDown) == .none)
}

@Test("j/k 在首尾停住")
func filesNavigationMovesWithinBounds() {
  #expect(resolve(0, .moveDown) == .select(1))
  #expect(resolve(4, .moveDown) == .none)
  #expect(resolve(2, .moveUp) == .select(1))
  #expect(resolve(0, .moveUp) == .none)
}

@Test("Space 只切换目录，文件上无动作")
func filesNavigationSpaceTogglesDirectoriesOnly() {
  #expect(resolve(0, .toggleDirectory) == .collapse("/r/a"))
  #expect(resolve(2, .toggleDirectory) == .expand("/r/a/sub"))
  #expect(resolve(1, .toggleDirectory) == .none)
  #expect(resolve(4, .toggleDirectory) == .none)
}

@Test("Enter、/、.、Esc 不改变树")
func filesNavigationNonTreeCommandsAreNoops() {
  for other in [DetailsFilesKeyCommand.activate, .focusFind, .toggleHidden, .returnFocus] {
    #expect(resolve(0, other) == .none)
  }
}
