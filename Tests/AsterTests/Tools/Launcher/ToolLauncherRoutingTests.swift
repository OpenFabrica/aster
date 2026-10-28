// 工具面板的键盘路由、快捷键取值解析与面板位置计算。
import AppKit
import Carbon
import Testing

@testable import Aster

/// 默认状态：焦点在搜索框、没有打开工具、没有输入法组字。
private let searching = ToolLauncherKeyRouter.Context(
  isToolOpen: false, isSearchFieldFocused: true, hasMarkedText: false)

/// 路由一个按键。
private func route(
  _ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = [],
  _ context: ToolLauncherKeyRouter.Context = searching
) -> ToolLauncherCommand? {
  ToolLauncherKeyRouter.command(
    keyCode: keyCode, characters: characters, modifiers: modifiers, context: context)
}

@Test("结果列表：方向键选择、↩ 打开、⌘↩ 预填、⌥↩ 开成 Pane、⌘1–9 快选、Esc 关面板")
func toolLauncherRoutesListKeys() {
  #expect(route(125) == .moveSelection(1))
  #expect(route(126) == .moveSelection(-1))
  #expect(route(36) == .open)
  #expect(route(76) == .open)
  #expect(route(36, nil, .command) == .prefillResult)
  #expect(route(36, nil, .option) == .openAsPane)
  #expect(route(18, "1", .command) == .quickSelect(1))
  #expect(route(25, "9", .command) == .quickSelect(9))
  #expect(route(29, "0", .command) == nil)
  #expect(route(53) == .closePanel)
  // 方向键自带的 function/numericPad 标记不算修饰键。
  #expect(route(125, nil, [.function, .numericPad]) == .moveSelection(1))
  // 普通字符交给搜索框。
  #expect(route(0, "a") == nil)
  #expect(route(36, nil, .shift) == .openInWindow)
}

@Test("⇧↩ 新窗口打开只在焦点位于搜索框时生效：工具自己的多行输入里 ⇧↩ 是换行")
func toolLauncherRoutesShiftReturnOnlyFromSearchField() {
  let searchWithTool = ToolLauncherKeyRouter.Context(isToolOpen: true, isSearchFieldFocused: true, hasMarkedText: false)
  #expect(route(36, nil, .shift, searchWithTool) == .openInWindow)
  let inTool = ToolLauncherKeyRouter.Context(isToolOpen: true, isSearchFieldFocused: false, hasMarkedText: false)
  #expect(route(36, nil, .shift, inTool) == nil)
  #expect(route(36, nil, [.shift, .command]) == nil)
}

@Test("工具打开后：↩ 与方向键归工具，Esc 先退出工具，⌘1–9 不再快选")
func toolLauncherRoutesKeysWhileToolIsOpen() {
  let inTool = ToolLauncherKeyRouter.Context(isToolOpen: true, isSearchFieldFocused: false, hasMarkedText: false)
  #expect(route(36, nil, [], inTool) == nil)
  #expect(route(125, nil, [], inTool) == nil)
  #expect(route(53, nil, [], inTool) == .exitTool)
  #expect(route(36, nil, .command, inTool) == .prefillResult)
  #expect(route(36, nil, .option, inTool) == .openAsPane)
  #expect(route(18, "1", .command, inTool) == nil)
  // 工具打开、焦点回到搜索框时继续输入交给工具，↩ 不重新打开别的行。
  let searchWithTool = ToolLauncherKeyRouter.Context(isToolOpen: true, isSearchFieldFocused: true, hasMarkedText: false)
  #expect(route(36, nil, [], searchWithTool) == nil)
  // 焦点不在搜索框（例如点了结果行）时方向键不归面板。
  let unfocused = ToolLauncherKeyRouter.Context(isToolOpen: false, isSearchFieldFocused: false, hasMarkedText: false)
  #expect(route(125, nil, [], unfocused) == nil)
  #expect(route(53, nil, [], unfocused) == .closePanel)
}

@Test("输入法组字时所有按键都交给输入法")
func toolLauncherLeavesKeysToInputMethodWhileComposing() {
  let composing = ToolLauncherKeyRouter.Context(isToolOpen: false, isSearchFieldFocused: true, hasMarkedText: true)
  for (keyCode, modifiers) in [(UInt16(36), NSEvent.ModifierFlags()), (53, []), (125, []), (36, .command)] {
    #expect(route(keyCode, nil, modifiers, composing) == nil)
  }
}

@Test("快捷键取值：none / optionSpace / controlOptionSpace，其它值不认")
func toolLauncherShortcutParsesSettingValues() {
  #expect(ToolLauncherShortcut(settingValue: "none") == ToolLauncherShortcut.none)
  #expect(ToolLauncherShortcut.none.keyCombination == nil)
  #expect(ToolLauncherShortcut(settingValue: "optionSpace")?.keyCombination?.keyCode == UInt32(kVK_Space))
  #expect(ToolLauncherShortcut(settingValue: "optionSpace")?.keyCombination?.modifiers == UInt32(optionKey))
  #expect(
    ToolLauncherShortcut(settingValue: "controlOptionSpace")?.keyCombination?.modifiers
      == UInt32(controlKey | optionKey))
  #expect(ToolLauncherShortcut(settingValue: "controlGrave") == nil)
  #expect(ToolLauncherShortcut(settingValue: "") == nil)
  #expect(ToolLauncherShortcut.defaultValue == ToolLauncherShortcut.none)
  #expect(ToolLauncherShortcut.settingKey == "tools.launcherShortcut")
}

@MainActor
@Test("热键配置：none 不注册也算成功，不认识的值报 paramErr")
func toolLauncherHotKeyConfiguresWithoutRegisteringForNone() {
  let hotKey = ToolLauncherHotKey()
  #expect(hotKey.configure(settingValue: "none") == noErr)
  #expect(hotKey.configure(settingValue: "none") == noErr)
  #expect(hotKey.configure(settingValue: "commandSpace") == OSStatus(paramErr))
  hotKey.stop()
}

@MainActor
@Test("面板位置：宽 720 居中，顶边固定往下长，放不下时上移再压缩")
func toolLauncherPanelFrameStaysInVisibleArea() {
  let screen = NSRect(x: -1440, y: 24, width: 1440, height: 876)
  let top = ToolLauncherController.anchorTop(in: screen)
  #expect(top == screen.maxY - screen.height / 6)
  let small = ToolLauncherController.frame(contentHeight: 300, top: top, in: screen)
  #expect(small.width == 720)
  #expect(small.midX == screen.midX)
  #expect(small.maxY == top)
  #expect(small.height == 300)
  // 放不下时整体上移，底边留 20pt。
  let tall = ToolLauncherController.frame(contentHeight: 800, top: top, in: screen)
  #expect(tall.minY == screen.minY + 20)
  #expect(tall.height == 800)
  // 比整个可见区域还高时压缩到上下各留 20pt。
  let huge = ToolLauncherController.frame(contentHeight: 5_000, top: top, in: screen)
  #expect(huge.height == screen.height - 40)
  #expect(huge.minY == screen.minY + 20)
  // 窄屏把宽度压到屏幕里。
  let narrow = ToolLauncherController.frame(
    contentHeight: 200, top: 700, in: NSRect(x: 0, y: 0, width: 600, height: 800))
  #expect(narrow.width == 560)
  #expect(narrow.minX == 20)
}

@MainActor
@Test("拖过的面板：左边与顶边按拖到的位置，越界时收回可见区域")
func toolLauncherPanelFrameFollowsDraggedPlacement() {
  let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
  let moved = ToolLauncherController.frame(contentHeight: 300, top: 600, left: 100, in: screen)
  #expect(moved.minX == 100)
  #expect(moved.maxY == 600)
  // 贴着可见区域上边时不再往下让 20pt。
  let atTop = ToolLauncherController.frame(contentHeight: 300, top: 900, left: 0, in: screen)
  #expect(atTop.maxY == 900)
  #expect(atTop.minX == 0)
  // 左右越界时收回屏幕里。
  #expect(ToolLauncherController.frame(contentHeight: 300, top: 600, left: 1_400, in: screen).maxX == 1440)
  #expect(ToolLauncherController.frame(contentHeight: 300, top: 600, left: -50, in: screen).minX == 0)
}
