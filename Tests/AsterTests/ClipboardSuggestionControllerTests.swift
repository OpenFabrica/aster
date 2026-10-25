import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("旧剪贴板开关不再让空提示符产生候选或拦截回车", arguments: [true, false])
@MainActor
func clipboardSuggestionPreferenceDoesNotPopulateEmptyPrompt(enabled: Bool) throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.clipboardSuggestion = enabled
  #expect(fixture.service.record(command: "brew install ripgrep", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(controller.currentResult.ghostText == nil)
  #expect(!controller.handle(.enter))
  #expect(!controller.handle(.escape))
  #expect(sent.isEmpty)
  #expect(controller.lastSubmittedCommand == nil)
}

@Test("实际历史候选不受旧剪贴板开关影响，来源保持为历史")
@MainActor
func clipboardSuggestionPreferenceDoesNotChangeRecordedCandidates() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let command = "brew install ripgrep"
  #expect(fixture.service.record(command: command, directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("brew i".utf8)[...])
  fixture.controls.value.clipboardSuggestion = true
  controller.refreshNow()
  let enabled = controller.currentResult.candidates
  #expect(enabled.contains { $0.insertText == command && $0.kind == .learnedCommand })
  #expect(!enabled.contains { $0.kind == .clipboard })

  fixture.controls.value.clipboardSuggestion = false
  controller.refreshNow()
  #expect(controller.currentResult.candidates.map(\.insertText) == enabled.map(\.insertText))
  #expect(controller.currentResult.candidates.map(\.kind) == enabled.map(\.kind))
}

@Test("无剪贴板注入时自动面板的 Return 仍需显式选择")
@MainActor
func clipboardSuggestionDoesNotOverrideCandidateSelection() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.clipboardSuggestion = true
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.map(\.insertText) == ["checkout", "cherry-pick"])
  #expect(!controller.currentResult.candidates.contains { $0.kind == .clipboard })
  #expect(!controller.handle(.enter))
  #expect(sent.isEmpty)
  #expect(controller.handle(.down))
  #expect(controller.handle(.enter))
  #expect(String(decoding: sent, as: UTF8.self) == "eckout")
  #expect(!sent.contains(0x0D) && !sent.contains(0x0A))
}
