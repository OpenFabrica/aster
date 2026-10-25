// Tab 的延迟回退不能把旧按键写入新输入、目录或已关闭的终端。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("Tab watchdog 不跨越输入、目录、配置、prompt 或生命周期", arguments: ["input", "directory", "controls", "prompt", "invalidate"])
@MainActor
func completionFallbackRejectsChangedContext(boundary: String) async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  var directory = "/project"
  let controller = TerminalAutocompleteController(service: fixture.service, sessionIdentifier: "fallback",
    controls: { fixture.controls.value }, currentDirectory: { directory })
  defer { controller.invalidate() }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  var sent: [UInt8] = []
  view.onEncodedInput = { sent += $0 }
  controller.attach(to: view)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("zzzznosuchcommand ".utf8)[...])
  let consumed = controller.handle(.tab)
  #expect(consumed)
  let watchdog = try #require(controller.fallbackTabTask)
  switch boundary {
  case "input": controller.receiveInput(Array("x".utf8)[...])
  case "directory": directory = "/other"
  case "controls": fixture.controls.value.autocompleteInlineSuggestion = false
  case "prompt": controller.receive(.promptStart)
  default: controller.invalidate()
  }
  await watchdog.value
  #expect(sent.isEmpty)
  #expect(!controller.shellCompletionActive)
}

@Test("Tab 查询已有面板时不再补发 Shell Tab")
@MainActor
func completionFallbackStopsWhenPanelAppears() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let controller = makeController(fixture)
  defer { controller.invalidate() }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  var sent: [UInt8] = []
  view.onEncodedInput = { sent += $0 }
  controller.attach(to: view)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  let consumed = controller.handle(.tab)
  #expect(consumed)
  await controller.fallbackTabTask?.value
  #expect(controller.panelVisible)
  #expect(sent.isEmpty)
  #expect(!controller.shellCompletionActive)
}
