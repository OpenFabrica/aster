import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 构造一个不依赖窗口的键盘按下事件。
private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
    windowNumber: 0, context: nil, characters: "\u{7F}",
    charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: keyCode)
}

@Test("⇧⌫ 与前向删除 + ⇧ 识别为忘记键，不带 ⇧ 仍是退格")
@MainActor
func shiftDeleteKeyResolution() throws {
  #expect(TerminalAutocompleteKey.resolve(try #require(keyEvent(keyCode: 51, modifiers: .shift))) == .shiftDelete)
  #expect(TerminalAutocompleteKey.resolve(try #require(keyEvent(keyCode: 117, modifiers: .shift))) == .shiftDelete)
  #expect(TerminalAutocompleteKey.resolve(try #require(keyEvent(keyCode: 51, modifiers: []))) == .backspace)
}

@Test("面板里选中整行历史后 ⇧⌫ 删除它并落盘，面板保持打开；规格候选不受影响")
@MainActor
func terminalAutocompleteForgetsSelectedHistory() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  func run(_ command: String) {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    controller.receive(.commandStart)
    controller.receive(.commandFinished(exitStatus: 0))
  }
  run("git stash list")
  run("git stash pop")
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git sta".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)
  // 没有选中时 ⇧⌫ 放行给 Shell。
  #expect(!controller.handle(.shiftDelete))

  let target = try #require(controller.currentResult.candidates.firstIndex { $0.insertText == "git stash pop" })
  for _ in 0...target { #expect(controller.handle(.down)) }
  #expect(controller.currentResult.candidates[controller.selectedIndex].insertText == "git stash pop")
  #expect(controller.handle(.shiftDelete))
  #expect(!controller.currentResult.candidates.contains { $0.insertText == "git stash pop" })
  #expect(controller.currentResult.candidates.contains { $0.insertText == "git stash list" })
  #expect(controller.panelVisible)
  #expect(controller.hasUserSelection)
  #expect(sent.isEmpty)

  // 已写入 learning.json：重新加载的服务也不再给出这条历史。
  let reloaded = try AutocompleteService(
    baseDirectory: fixture.directory,
    bundledSpecURL: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Resources/autocomplete/fig-specs.json"))
  let learned = reloaded.suggestions(
    line: "git sta", directory: "/project", sessionIdentifier: "session", controls: fixture.controls.value
  ).candidates.filter { $0.kind == .learnedCommand }.map(\.insertText)
  #expect(learned == ["git stash list"])

  // 选中规格子命令（stash）时 ⇧⌫ 吞键但不改变任何候选。
  let spec = try #require(controller.currentResult.candidates.firstIndex { !$0.isLearned })
  let before = controller.currentResult.candidates
  while controller.selectedIndex != spec { #expect(controller.handle(.down)) }
  #expect(controller.handle(.shiftDelete))
  #expect(controller.currentResult.candidates == before)
  #expect(sent.isEmpty)
}
