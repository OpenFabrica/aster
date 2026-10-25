// 动态来源可能晚于后续输入返回；验证候选归属以及用户已选择的身份。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

private actor CompletionQueryGate {
  private var pending: CheckedContinuation<[CompletionDynamicItem], Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  func query() async -> [CompletionDynamicItem] {
    await withCheckedContinuation { continuation in
      pending = continuation
      observers.forEach { $0.resume() }
      observers.removeAll()
    }
  }

  func started() async {
    if pending != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func release(_ items: [CompletionDynamicItem]) {
    pending?.resume(returning: items)
    pending = nil
  }
}

@MainActor
private func dynamicLifecycleService(_ directory: URL, gate: CompletionQueryGate) throws -> AutocompleteService {
  let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/autocomplete/fig-specs.json")
  return try AutocompleteService(baseDirectory: directory, bundledSpecURL: bundled,
    nativeDynamicQuery: { _, _, _, _ in await gate.query() })
}

@Test("静态候选立即显示，动态结果不会改变已选候选的Tab目标")
@MainActor
func completionDynamicArrivalPreservesSelectedCandidate() async throws {
  let directory = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let gate = CompletionQueryGate()
  let service = try dynamicLifecycleService(directory, gate: gate)
  _ = service.submit(command: "git change", directory: "/seed", ignorePatterns: [], sessionIdentifier: "seed")
  var controls = ControlConfiguration()
  controls.autocompleteCandidatePanel = .automatic
  let controller = TerminalAutocompleteController(service: service, sessionIdentifier: "test",
    controls: { controls }, currentDirectory: { "/project" })
  defer { controller.invalidate() }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
  var sent: [UInt8] = []
  view.onEncodedInput = { sent += $0 }
  controller.attach(to: view)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.contains { $0.displayText == "checkout" })
  #expect(controller.handle(.down))
  let chosen = controller.currentResult.candidates[controller.selectedIndex].displayText
  await gate.started()
  await gate.release([.init(name: "change", kind: .subcommand)])
  await controller.dynamicQuerySettled()
  #expect(controller.currentResult.candidates.first?.displayText == "change")
  #expect(controller.currentResult.candidates[controller.selectedIndex].displayText == chosen)
  #expect(controller.handle(.tab))
  #expect(sent == [127, 127] + Array((chosen + " ").utf8))
  #expect(controller.lastSubmittedCommand == nil)
}

@Test("动态结果不越过输入、目录、配置、prompt和控制器生命周期", arguments: ["input", "directory", "controls", "prompt", "invalidate"])
@MainActor
func completionDynamicLateResultIsDiscarded(boundary: String) async throws {
  let directory = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let gate = CompletionQueryGate()
  let service = try dynamicLifecycleService(directory, gate: gate)
  var currentDirectory = "/project"
  var controls = ControlConfiguration()
  let controller = TerminalAutocompleteController(service: service, sessionIdentifier: "test",
    controls: { controls }, currentDirectory: { currentDirectory })
  defer { controller.invalidate() }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  let pending = try #require(controller.dynamicTask)
  await gate.started()
  switch boundary {
  case "input": controller.receiveInput(Array("e".utf8)[...])
  case "directory": currentDirectory = "/other"
  case "controls": controls.autocompleteInlineSuggestion = false
  case "prompt": controller.receive(.promptStart)
  default: controller.invalidate()
  }
  await gate.release([.init(name: "changed-by-old-query")])
  await pending.value
  #expect(!controller.currentResult.candidates.contains { $0.displayText == "changed-by-old-query" })
}

@Test("异步重算移除已选项后取消选择，不把Tab或Return指向替代项")
@MainActor
func completionDynamicDisappearingSelectionRequiresNewSelection() async throws {
  let directory = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let gate = CompletionQueryGate()
  let service = try dynamicLifecycleService(directory, gate: gate)
  _ = service.submit(command: "git chosen-history", directory: "/project", ignorePatterns: [], sessionIdentifier: "seed")
  var controls = ControlConfiguration()
  controls.autocompleteCandidatePanel = .automatic
  let controller = TerminalAutocompleteController(service: service, sessionIdentifier: "test",
    controls: { controls }, currentDirectory: { "/project" })
  defer { controller.invalidate() }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
  var sent: [UInt8] = []
  view.onEncodedInput = { sent += $0 }
  controller.attach(to: view)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.handle(.down))
  let selected = controller.currentResult.candidates[controller.selectedIndex]
  #expect(selected.displayText == "git chosen-history")
  await gate.started()
  #expect(service.forget(candidate: selected, line: "git ch", directory: "/project"))
  await gate.release([.init(name: "change")])
  await controller.dynamicQuerySettled()
  #expect(!controller.hasUserSelection)
  #expect(!controller.handle(.enter))
  let queried = controller.handle(.tab)
  #expect(queried)
  #expect(sent.isEmpty)
  #expect(!controller.hasUserSelection)
  await gate.started()
  await gate.release([])
  await controller.dynamicQuerySettled()
}

@Test("远端目录与未完成命令根不启动本机动态查询")
@MainActor
func completionDynamicDoesNotQueryRemoteOrRootPrefix() async throws {
  let directory = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let gate = CompletionQueryGate()
  let service = try dynamicLifecycleService(directory, gate: gate)
  #expect(await service.dynamicCandidates(line: "git checkout ", directory: "ssh://host/project").isEmpty)
  #expect(await service.dynamicCandidates(line: "git", directory: "/project").isEmpty)
}
