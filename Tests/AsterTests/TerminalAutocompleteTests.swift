import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("可靠prompt的Tab删除原始token，写入候选和尾空格")
@MainActor
func terminalAutocompleteAcceptsCandidateByReplacingRawToken() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteInput = { controller.receiveInput($0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  controller.refreshNow()
  // Tab 只接受可见 ghost；必须先让 PTY 回显本次输入，ghost 才会真正显示。
  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()

  #expect(controller.currentResult.candidates.prefix(2).map(\.insertText) == ["checkout"])
  #expect(controller.currentResult.ghostText == "kout")
  #expect(controller.handle(.tab))
  #expect(sent == Array(repeating: UInt8(127), count: 4) + Array("checkout ".utf8))
  #expect(controller.lastSubmittedCommand == nil)
}

@Test("不可见ghost不接受，Tab查询超时后只回退一次给Shell")
@MainActor
func terminalAutocompleteRefusesInvisibleGhostWhenShellSuggestionOwnsLine() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  // zsh-autosuggestions 等插件把自己的灰色建议画进网格，可见行不再以本地输入结尾，
  // 回显校验因此一直不通过，Aster ghost 保持隐藏。此时**绝不能**吞掉 Tab 去插入
  // 用户从未见过的候选文本。Tab 先重新查询，仍没有可见结果时由 watchdog 回退给 Shell。
  view.dataReceived(slice: Array("git checkout -b feature".utf8)[...])
  await Task.yield()

  #expect(controller.inlineGhostText == nil)
  #expect(controller.handle(.tab))
  #expect(!controller.hasUserSelection)
  #expect(sent.isEmpty)
  await controller.fallbackTabTask?.value
  #expect(sent == [9])
  #expect(controller.shellCompletionActive)
  #expect(!controller.handle(.tab))

}

@Test("Aster 没有候选时 Tab 仍原样交给 Shell 自己的补全")
@MainActor
func terminalAutocompletePassesTabToShellWithoutCandidates() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("zzzznosuchcommand ".utf8)[...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(controller.handle(.tab))
  #expect(sent.isEmpty)
  await controller.fallbackTabTask?.value
  #expect(sent == [9])
  #expect(!controller.handle(.tab))
  #expect(!controller.panelVisible)

}

@Test("Shell 尚未回显本次输入时不显示 inline suggestion")
@MainActor
func terminalAutocompleteWaitsForEchoBeforeShowingInlineSuggestion() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  controller.refreshNow()

  let overlay = try #require(
    view.subviews.first {
      String(describing: type(of: $0)).contains("TerminalAutocompleteOverlayView")
    }
  )
  let ghost = try #require(overlay.subviews.compactMap { $0 as? NSTextField }.first)
  // 本地 tracker 比 PTY 回显更早拿到输入。此窗口期若显示 ghost，它会锚定在旧光标上，
  // 与 Shell 随后绘制的 `git chec` 发生重叠。
  #expect(ghost.isHidden)

  // 终端可能在输入回显之前送达状态控制序列或其他输出；这不能被误判成当前输入
  // 已经出现在网格中，否则 ghost 会锚定旧光标并覆盖随后回显的字符。
  view.dataReceived(slice: Array("\u{1B}[?25l".utf8)[...])
  await Task.yield()

  #expect(ghost.isHidden)

  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()

  #expect(ghost.stringValue == "kout")
  #expect(!ghost.isHidden)
  #expect(ghost.frame.minX >= view.caretFrame.maxX - 0.5)
}

@Test("后续输入会立即隐藏上一轮 inline suggestion")
@MainActor
func terminalAutocompleteHidesStaleGhostBeforeDebouncedRefresh() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()

  let overlay = try #require(
    view.subviews.first {
      String(describing: type(of: $0)).contains("TerminalAutocompleteOverlayView")
    }
  )
  let ghost = try #require(overlay.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(!ghost.isHidden)

  // 输入 tracker 会立刻收到下一个字符，而候选重算有 150ms debounce；旧后缀若继续
  // 留在屏幕上，就会与 Shell 随后的新回显重叠。
  controller.receiveInput(Array("e".utf8)[...])

  #expect(ghost.isHidden)
}

@Test("唯一候选先关闭可见 inline，再按 Escape 可打开单项面板")
@MainActor
func terminalAutocompleteEscapeOpensSingleCandidatePanel() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .escape
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()

  #expect(controller.currentResult.candidates.map(\.insertText) == ["checkout"])
  #expect(controller.handle(.escape))
  #expect(!controller.panelVisible)
  #expect(controller.handle(.escape))
  #expect(controller.panelVisible)
  #expect(!controller.hasUserSelection)
  let overlay = try #require(view.subviews.compactMap { $0 as? TerminalAutocompleteOverlayView }.first)
  #expect(!overlay.panelContainer.isHidden)
  #expect(overlay.panel.arrangedSubviews.count == 1)
}

@Test("Shell 历史键使当前 prompt 不可靠并立即停用候选")
@MainActor
func terminalAutocompleteHidesAfterUnreconstructableInput() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(!controller.currentResult.candidates.isEmpty)

  controller.receiveInput([0x1B, 0x5B, 0x41][...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(!controller.panelVisible)
}

@Test("光标不在行尾时隐藏补全并保留 Right Arrow 的 Shell 编辑语义")
@MainActor
func terminalAutocompleteHidesWhileEditingMiddleOfLine() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.contains { $0.insertText == "checkout" })
  #expect(controller.inlineGhostText == nil)

  controller.receiveInput([0x1B, 0x5B, 0x44][...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(!controller.handle(.right))
}

@Test("提交时记录整行和词频，重复完成事件不会再次计数")
@MainActor
func terminalAutocompleteLearnsOnSubmissionBeforeCommandFinishes() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git status\n".utf8)[...])

  let submitted = fixture.service.completionStore.state
  #expect(submitted.fullLines.map(\.command) == ["git status"])
  #expect(submitted.fullLines.first?.count == 1)
  #expect(submitted.history.first { $0.command == "" && $0.token == "git" }?.count == 1)

  controller.receive(.commandStart)
  controller.receiveOutput(Array("done\n".utf8)[...])
  controller.receive(.commandFinished(exitStatus: 0))
  controller.receive(.commandFinished(exitStatus: 0))
  #expect(fixture.service.completionStore.state == submitted)

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git s".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.contains {
    $0.insertText == "git status" && $0.kind == .learnedCommand
  })
}

@Test("Ghostty commandStart 先到时仍接收排队中的回车并发布完整命令")
@MainActor
func terminalAutocompleteAcceptsQueuedSubmitAfterCommandStart() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  var submitted: [String] = []
  controller.onCommandSubmitted = { submitted.append($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("ssh root@ubuntu@orb".utf8)[...])
  // Ghostty 的 OSC observer 与 PTY write 原来走两条主线程队列；快速命令会让 C
  // marker 抢在最后一个回车 callback 前到达。
  controller.receive(.commandStart)
  controller.receiveInput([0x0D][...])

  #expect(submitted == ["ssh root@ubuntu@orb"])
  #expect(controller.lastSubmittedCommand == "ssh root@ubuntu@orb")
}

@Test("手动打开的候选面板在继续输入时保持打开并按新前缀收窄")
@MainActor
func terminalAutocompleteKeepsManualPanelOpenWhileTyping() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .escape
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git c".utf8)[...])
  controller.refreshNow()
  // 多个候选没有自动预览；Escape 直接进入手动选择。
  view.dataReceived(slice: Array("git c".utf8)[...])
  await Task.yield()
  #expect(controller.handle(.escape))
  #expect(controller.panelVisible)

  // Otty:"Keep typing to refine it"。旧实现在 receiveInput 里无条件关面板，
  // 于是每敲一个字符都要重按 Escape。
  controller.receiveInput(Array("h".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)
  #expect(controller.currentResult.candidates.first?.insertText == "checkout")
}

@Test("空 prompt 即使已有目录历史也无候选，输入首字符后自动展开")
@MainActor
func terminalAutocompleteDoesNotAutoOpenPanelOnEmptyPrompt() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let controller = makeController(fixture)
  for command in ["git status", "git commit -m x", "ls"] {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    controller.receive(.commandStart)
    controller.receive(.commandFinished(exitStatus: 0))
  }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)
  #expect(controller.currentResult.ghostText == nil)
  #expect(!controller.panelVisible)
  #expect(!controller.handle(.escape))
  #expect(!controller.panelVisible)

  controller.receiveInput(Array("g".utf8)[...])
  controller.refreshNow()
  #expect(!controller.currentResult.candidates.isEmpty)
  #expect(controller.panelVisible)
}

@Test("127 清除本次命令历史，其它非零退出码保留已提交的整行")
@MainActor
func terminalAutocompleteCleansOnlyCommandNotFoundExitStatus() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  func run(_ command: String, exitStatus: Int, output: String) {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    #expect(fixture.service.completionStore.state.fullLines.contains { $0.command == command })
    controller.receive(.commandStart)
    controller.receiveOutput(Array(output.utf8)[...])
    controller.receive(.commandFinished(exitStatus: exitStatus))
  }
  run("sw", exitStatus: 127, output: "zsh: command not found: sw\n")
  run("./notexec", exitStatus: 126, output: "zsh: permission denied: ./notexec\n")
  run("gti status", exitStatus: 1, output: "zsh: command not found: gti\n")
  run("git push", exitStatus: 1, output: "fatal: no upstream\n")
  run("ls", exitStatus: 0, output: "")

  let learned = fixture.service.completionStore.state.fullLines.map(\.command)
  #expect(!learned.contains("sw"))
  #expect(learned.contains("./notexec"))
  #expect(learned.contains("gti status"))
  #expect(learned.contains("git push"))
  #expect(learned.contains("ls"))
}

@Test("失败输出不生成 cd 纠错或 git pull 重试命令")
@MainActor
func terminalAutocompleteDoesNotInjectStructuralCorrections() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let cwd = fixture.directory.appendingPathComponent("cwd", isDirectory: true)
  try FileManager.default.createDirectory(
    at: cwd.appendingPathComponent("project", isDirectory: true), withIntermediateDirectories: true)
  let controller = TerminalAutocompleteController(
    service: fixture.service, sessionIdentifier: "session",
    controls: { fixture.controls.value }, currentDirectory: { cwd.path })
  func run(_ command: String, output: String, prefix: String) {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    controller.receive(.commandStart)
    controller.receiveOutput(Array(output.utf8)[...])
    controller.receive(.commandFinished(exitStatus: 1))
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.refreshNow()
    #expect(controller.currentResult.candidates.isEmpty)
    controller.receiveInput(Array(prefix.utf8)[...])
    controller.refreshNow()
    #expect(!controller.currentResult.candidates.contains { $0.kind == .correction })
  }
  run("cd porject", output: "cd: no such file or directory: porject\n", prefix: "cd p")
  #expect(!controller.currentResult.candidates.contains {
    $0.kind == .learnedCommand && $0.insertText == "cd project"
  })
  run("git push", output: "Updates were rejected because the remote contains work.\n", prefix: "git p")
  #expect(!controller.currentResult.candidates.contains { $0.insertText == "git pull --rebase && git push" })
}

@Test("Escape 关闭自动面板后本轮 prompt 内不再自动弹回")
@MainActor
func terminalAutocompleteEscapeKeepsAutoPanelClosedForRestOfPrompt() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let controller = makeController(fixture)

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git c".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)

  #expect(controller.handle(.escape))
  #expect(!controller.panelVisible)
  // 旧实现里 refreshNow 会无条件把可见性算回 true，面板自己弹回来。
  controller.receiveInput(Array("h".utf8)[...])
  controller.refreshNow()
  #expect(!controller.panelVisible)

  // 下一条 prompt 解除闩锁。
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git c".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)
}

@Test("自动面板不抢先选择，方向键选中后 Return 接受")
@MainActor
func terminalAutocompleteAutoPanelWaitsForSelection() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
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
  #expect(controller.panelVisible)
  #expect(!controller.hasUserSelection)
  #expect(!controller.handle(.enter))
  #expect(!controller.panelVisible)
  controller.refreshNow()
  #expect(controller.handle(.down))
  #expect(controller.hasUserSelection)
  #expect(controller.selectedIndex == 0)
  #expect(controller.handle(.enter))
  #expect(sent == [127, 127] + Array("checkout ".utf8))
}

@Test("手动面板初始无选择，方向键选择后Return替换当前词")
@MainActor
func terminalAutocompleteManualPanelRequiresSelectionForReturn() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .escape
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git ch".utf8)[...])
  await Task.yield()
  #expect(controller.handle(.escape))
  #expect(controller.panelVisible)
  #expect(!controller.hasUserSelection)
  #expect(controller.handle(.down))
  #expect(controller.handle(.enter))
  #expect(sent == [127, 127] + Array("checkout ".utf8))

}

@Test("inline 与候选面板同时关闭时完全不查询规格库")
@MainActor
func terminalAutocompleteSkipsSuggestionsWhenInlineAndPanelDisabled() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteInlineSuggestion = false
  fixture.controls.value.autocompleteCandidatePanel = .disabled
  let controller = makeController(fixture)

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(controller.currentResult.ghostText == nil)
  #expect(!controller.panelVisible)
}

@Test("自动面板保留唯一候选，候选为空才收起")
@MainActor
func terminalAutocompleteAutoPanelClosesOnlyWhenCandidatesAreEmpty() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  let overlay = try #require(view.subviews.compactMap { $0 as? TerminalAutocompleteOverlayView }.first)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git c".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)

  controller.receiveInput(Array("herry-pi".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.map(\.insertText) == ["cherry-pick"])
  #expect(controller.panelVisible)
  #expect(!overlay.panelContainer.isHidden)
  #expect(overlay.panel.arrangedSubviews.count == 1)

  controller.receiveInput(Array("zzzz".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)
  #expect(!controller.panelVisible)
  #expect(overlay.panelContainer.isHidden)
}

@Test("滚动视窗以最小移动跟随选中项并覆盖循环选择")
@MainActor
func terminalAutocompleteScrollsWindowToKeepSelectionVisible() {
  let rows = 8
  // 向下走到第 9 条时窗口只前移一行；再回绕到 0 时窗口跳回顶部。
  #expect(
    TerminalAutocompleteController.clampedFirstVisibleIndex(
      current: 0, selected: 8, count: 20, visibleRows: rows) == 1)
  #expect(
    TerminalAutocompleteController.clampedFirstVisibleIndex(
      current: 1, selected: 0, count: 20, visibleRows: rows) == 0)
  // 从首行按 ↑ 回绕到末行时窗口贴到底部。
  #expect(
    TerminalAutocompleteController.clampedFirstVisibleIndex(
      current: 0, selected: 19, count: 20, visibleRows: rows) == 12)
  // 候选装得下时不滚动。
  #expect(
    TerminalAutocompleteController.clampedFirstVisibleIndex(
      current: 3, selected: 2, count: 5, visibleRows: rows) == 0)
}

@Test("命令输出中的纠错提示不成为补全来源")
@MainActor
func terminalAutocompleteDoesNotParseCorrectionFromOutput() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git stauts\r".utf8)[...])
  controller.receive(.commandStart)
  controller.receiveOutput(Array("git: 'stauts' is not a git command. The most similar command is status\n".utf8)[...])
  controller.receive(.commandFinished(exitStatus: 1))
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)
  #expect(controller.currentResult.ghostText == nil)

  controller.receiveInput(Array("git st".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.contains { $0.insertText == "status" && $0.kind == .subcommand })
  #expect(!controller.currentResult.candidates.contains { $0.kind == .correction })
  #expect(!fixture.service.completionStore.state.fullLines.contains { $0.command == "git status" })
}

@Test("成功 clone 不生成下一步 cd 建议，已有目录仍能正常补全")
@MainActor
func terminalAutocompleteDoesNotInjectCdAfterSuccessfulClone() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let cwd = fixture.directory.appendingPathComponent("cwd", isDirectory: true)
  try FileManager.default.createDirectory(
    at: cwd.appendingPathComponent("dxy-device"), withIntermediateDirectories: true)
  fixture.controls.value.autocompleteOnDeviceLearning = false
  let controller = TerminalAutocompleteController(
    service: fixture.service, sessionIdentifier: "session",
    controls: { fixture.controls.value }, currentDirectory: { cwd.path })
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git clone ssh://git@example.com/dxyc/dxy-device.git\r".utf8)[...])
  controller.receive(.commandStart)
  controller.receive(.commandFinished(exitStatus: 0))
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)
  #expect(controller.currentResult.ghostText == nil)

  controller.receiveInput(Array("cd d".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.contains { $0.kind == .folder && $0.displayText == "dxy-device/" })
  #expect(!controller.currentResult.candidates.contains { $0.kind == .followUp })
}

@Test("创建 venv 或成功 commit 不生成后续动作")
@MainActor
func terminalAutocompleteDoesNotInjectFollowUpCommands() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let cwd = fixture.directory.appendingPathComponent("cwd", isDirectory: true)
  try FileManager.default.createDirectory(
    at: cwd.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
  try Data().write(to: cwd.appendingPathComponent(".venv/bin/activate"))
  let controller = TerminalAutocompleteController(
    service: fixture.service, sessionIdentifier: "session",
    controls: { fixture.controls.value }, currentDirectory: { cwd.path })
  for command in ["python3 -m venv .venv", "git commit -m \"feat: x\""] {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array((command + "\r").utf8)[...])
    controller.receive(.commandStart)
    controller.receive(.commandFinished(exitStatus: 0))
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.refreshNow()
    #expect(controller.currentResult.candidates.isEmpty)
    #expect(controller.currentResult.ghostText == nil)
  }
  #expect(!fixture.service.completionStore.state.fullLines.contains {
    $0.command == "source .venv/bin/activate" || $0.command == "git push"
  })
}

@Test("Shell 历史执行使用屏幕命令记录，剔除右侧提示符且不跨 prompt 复用")
@MainActor
func terminalAutocompleteLearnsScreenCommandWithoutFollowUp() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  for screenLine in ["mkdir demo", "mkdir demo            14:30:00 main"] {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\u{1B}[A\r".utf8)[...])
    controller.receiveScreenCommand(screenLine)
    controller.receive(.commandStart)
    controller.receive(.commandFinished(exitStatus: 0))
  }
  let stored = fixture.service.completionStore.state
  #expect(stored.fullLines.map(\.command) == ["mkdir demo"])
  #expect(stored.fullLines.first?.count == 2)

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)
  controller.receiveInput(Array("\u{1B}[A\r".utf8)[...])
  controller.receive(.commandStart)
  controller.receive(.commandFinished(exitStatus: 0))
  #expect(fixture.service.completionStore.state == stored)
}

@Test("Shell Tab 后等待屏幕完整命令，只记录最终文本而不记录键盘前缀")
@MainActor
func terminalAutocompleteLearnsScreenCommandAfterShellTab() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteShortcut = .disabled
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  #expect(!controller.handle(.tab))
  controller.receiveInput([0x09][...])
  controller.receiveInput([0x0D][...])
  #expect(fixture.service.completionStore.state.fullLines.isEmpty)
  #expect(fixture.service.completionStore.state.history.isEmpty)

  controller.receiveScreenCommand("git checkout main")
  controller.receive(.commandStart)
  let submitted = fixture.service.completionStore.state
  #expect(submitted.fullLines.map(\.command) == ["git checkout main"])
  #expect(!submitted.history.contains { $0.token == "chec" })
  controller.receive(.commandFinished(exitStatus: 0))
  #expect(fixture.service.completionStore.state == submitted)
}

@Test("屏幕回读保留前导空格的不记录语义", arguments: [" git status", "  git status"])
@MainActor
func terminalAutocompleteSkipsScreenCommandWithLeadingSpace(command: String) throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("\u{1B}[A\r".utf8)[...])
  controller.receiveScreenCommand(command)
  controller.receive(.commandStart)
  controller.receive(.commandFinished(exitStatus: 0))
  #expect(fixture.service.completionStore.state.fullLines.isEmpty)
  #expect(fixture.service.completionStore.state.history.isEmpty)
}

@Test("旧控制器失效后的迟到事件不能清理或污染同会话的新提交")
@MainActor
func terminalAutocompleteInvalidatedControllerCannotChangeReplacementSubmission() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let previous = makeController(fixture)
  previous.receive(.promptStart)
  previous.receive(.inputStart)
  previous.receiveInput(Array("git status\r".utf8)[...])
  previous.receive(.commandStart)
  previous.invalidate()
  previous.invalidate()

  let replacement = makeController(fixture)
  replacement.receive(.promptStart)
  replacement.receive(.inputStart)
  replacement.receiveInput(Array("git checkout main\r".utf8)[...])
  let submitted = fixture.service.completionStore.state
  #expect(submitted.fullLines.contains { $0.command == "git checkout main" })

  previous.receive(.commandFinished(exitStatus: 127))
  previous.receive(.promptStart)
  previous.receive(.inputStart)
  previous.receiveInput(Array("git branch pollution\r".utf8)[...])
  previous.receiveScreenCommand("git branch pollution")
  previous.receive(.commandStart)
  previous.refreshNow()
  #expect(!previous.handle(.tab))
  #expect(previous.currentResult.candidates.isEmpty)
  #expect(fixture.service.completionStore.state == submitted)

  replacement.receive(.commandStart)
  replacement.receive(.commandFinished(exitStatus: 0))
  #expect(fixture.service.completionStore.state == submitted)
}

@MainActor
func makeController(
  _ fixture: (directory: URL, service: AutocompleteService, controls: MutableAutocompleteControls)
) -> TerminalAutocompleteController {
  TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
}

final class MutableAutocompleteControls {
  var value = ControlConfiguration()
}

@MainActor
func makeTerminalAutocompleteFixture() throws -> (
  directory: URL, service: AutocompleteService, controls: MutableAutocompleteControls
) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-terminal-autocomplete-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let service = try AutocompleteService(
    baseDirectory: directory,
    bundledSpecURL: repositoryRoot.appendingPathComponent("Resources/autocomplete/fig-specs.json")
  )
  return (directory, service, MutableAutocompleteControls())
}

@Test("Shell 后续绘制建议或回移光标时立即隐藏 ghost，避免叠字")
@MainActor
func terminalAutocompleteRevalidatesGhostAfterEveryOutput() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()
  let overlay = try #require(view.subviews.compactMap { $0 as? TerminalAutocompleteOverlayView }.first)
  let ghost = try #require(overlay.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(!ghost.isHidden)

  // Shell 插件可在输入回显后的独立分片绘制建议，再把光标退回真实输入末尾。
  view.dataReceived(slice: Array("kout\u{1B}[4D".utf8)[...])
  await Task.yield()
  #expect(ghost.isHidden)

  view.dataReceived(slice: Array("\u{1B}[K".utf8)[...])
  await Task.yield()
  #expect(!ghost.isHidden)

  // 行文本仍以 git chec 结尾，但光标已回到行首，不能继续以旧的回显结论绘制。
  view.dataReceived(slice: Array("\r".utf8)[...])
  await Task.yield()
  controller.refreshNow()
  #expect(ghost.isHidden)
}

@Test("Pane 放不下候选面板时 Return 不接受隐藏候选")
@MainActor
func terminalAutocompleteDoesNotAcceptClippedPanel() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  fixture.controls.value.autocompleteInlineSuggestion = false
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(!controller.currentResult.candidates.isEmpty)
  #expect(!controller.handle(.enter))
  #expect(sent.isEmpty)
}

@Test("多个候选不擅自预览第一条，用户选择后预览对应候选")
@MainActor
func terminalAutocompleteContextPreviewsSelectedCandidate() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git ch".utf8)[...])
  await Task.yield()
  let overlay = try #require(view.subviews.compactMap { $0 as? TerminalAutocompleteOverlayView }.first)
  let ghost = try #require(overlay.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(ghost.isHidden)
  #expect(!controller.hasUserSelection)
  #expect(controller.handle(.down))
  #expect(controller.handle(.down))
  #expect(ghost.stringValue == "erry-pick")
}

@Test("跳过敏感命令开关控制整行记录，关闭时保存原始文本")
@MainActor
func terminalAutocompleteSkipsSecretCommandsWhenEnabled() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  func run(_ command: String, exitStatus: Int = 0, output: String = "") {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    controller.receive(.commandStart)
    if !output.isEmpty { controller.receiveOutput(Array(output.utf8)[...]) }
    controller.receive(.commandFinished(exitStatus: exitStatus))
  }
  func learned(_ prefix: String) -> [String] {
    fixture.service.suggestions(
      line: prefix, directory: "/project", sessionIdentifier: "session", controls: fixture.controls.value
    ).candidates.filter { $0.kind == .learnedCommand }.map(\.insertText)
  }

  fixture.controls.value.autocompleteSkipSecrets = true
  run("export DEPLOY_TOKEN=abcdef123456")
  #expect(learned("export").isEmpty)
  // 127 清除本次失败命令；输出不成为额外建议来源。
  run("gti push --token abcdef", exitStatus: 127, output: "zsh: command not found: gti")
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(!controller.currentResult.candidates.contains { $0.kind == .correction })

  fixture.controls.value.autocompleteSkipSecrets = false
  run("export DEPLOY_TOKEN=abcdef123456")
  #expect(learned("export") == ["export DEPLOY_TOKEN=abcdef123456"])
}

@Test("同分历史无公共预览，需要方向键明确选中后接受整行")
@MainActor
func terminalAutocompleteDoesNotPreviewSharedPrefixOfConflictingHistory() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  for _ in 0..<2 {
    for command in ["git commit -m wip", "git commit --amend"] {
      controller.receive(.promptStart)
      controller.receive(.inputStart)
      controller.receiveInput(Array("\(command)\n".utf8)[...])
      controller.receive(.commandStart)
      controller.receive(.commandFinished(exitStatus: 0))
    }
  }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ".utf8)[...])
  controller.refreshNow()
  let lines = controller.currentResult.candidates.filter { $0.kind == .learnedCommand }.map(\.insertText)
  #expect(lines.contains("git commit -m wip") && lines.contains("git commit --amend"))
  #expect(controller.inlineSuggestion == nil)
  #expect(controller.inlineGhostText == nil)
  let first = try #require(controller.currentResult.candidates.first)
  let suffix = try #require(first.appendableSuffix(from: "git "))
  view.dataReceived(slice: Array("git ".utf8)[...])
  await Task.yield()
  #expect(controller.handle(.down))
  #expect(controller.hasUserSelection)
  #expect(sent.isEmpty)
  #expect(controller.inlineGhostText == suffix)
  #expect(controller.handle(.tab))
  #expect(sent == Array(repeating: UInt8(127), count: "git ".unicodeScalars.count) + Array(first.insertText.utf8))

}

@Test("多个候选时首条历史用得更多且最近用过，直接预览整行，Tab 接受它")
@MainActor
func terminalAutocompletePreviewsClearlyLeadingHistory() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  func run(_ command: String) {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    controller.receive(.commandStart)
    controller.receive(.commandFinished(exitStatus: 0))
  }
  // fix 先用一次，wip 随后用两次：后者次数更多且最近用过。提交信息是自由文本，
  // 不会和规格选项归并加分，排序只由学习历史决定。
  run("git commit -m fix")
  run("git commit -m wip")
  run("git commit -m wip")
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git commit -m ".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.count > 1)
  #expect(controller.currentResult.candidates.first?.insertText == "git commit -m wip")
  #expect(controller.inlineSuggestion == .candidate(0))
  #expect(controller.inlineGhostText == "wip")

  view.dataReceived(slice: Array("git commit -m ".utf8)[...])
  await Task.yield()
  #expect(controller.handle(.tab))
  #expect(sent == Array(repeating: UInt8(127), count: "git commit -m ".unicodeScalars.count) + Array("git commit -m wip".utf8))
}

@Test("自动多项无选择时Tab交给Shell，直到其他按键解除接管")
@MainActor
func terminalAutocompleteUnselectedMultipleTabHandsOffToShell() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
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
  #expect(!controller.hasUserSelection)
  #expect(!controller.handle(.tab))
  #expect(controller.shellCompletionActive)
  #expect(!controller.panelVisible)
  #expect(!controller.handle(.tab))
  #expect(!controller.handle(.down))
  #expect(!controller.handle(.left))
  #expect(sent.isEmpty)
  #expect(!controller.handle(.other))
  #expect(!controller.shellCompletionActive)

}

@Test("Ctrl-C 后立即输入的命令保留到新提示符，不丢前缀")
@MainActor
func terminalAutocompleteKeepsTypeaheadAcrossInterrupt() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("old command".utf8)[...])
  controller.receiveInput([0x03][...])
  controller.receiveInput(Array("git c".utf8)[...])
  controller.receive(.promptStart)
  controller.receiveInput(Array("h".utf8)[...])
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.map(\.insertText) == ["checkout", "cherry-pick"])
}

@Test("提示符过渡输入有大小上限，超限停用补全并在下轮恢复")
@MainActor
func terminalAutocompleteBoundsPromptTypeahead() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  controller.receive(.promptStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.map(\.insertText) == ["checkout", "cherry-pick"])

  controller.receive(.promptStart)
  controller.receiveInput(Array(repeating: UInt8(ascii: "x"), count: 4_097)[...])
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.map(\.insertText) == ["checkout", "cherry-pick"])
}

@Test("Tab 直接接受 Shell 已显示的建议，不打开面板或触发原生补全")
@MainActor
func terminalAutocompleteTabAcceptsVisibleShellSuffix() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git checkout\u{1B}[6D".utf8)[...])
  await Task.yield()
  #expect(controller.handle(.tab))
  #expect(String(decoding: sent, as: UTF8.self) == "eckout")
  #expect(!controller.panelVisible)
}

@Test("手动面板收窄到一个候选后保持打开并允许再次打开")
@MainActor
func terminalAutocompleteSingleCandidateKeepsManualPanelOpen() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .escape
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.handle(.escape))
  #expect(controller.panelVisible)
  controller.receiveInput(Array("ec".utf8)[...])
  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()
  controller.refreshNow()
  #expect(controller.currentResult.candidates.map(\.insertText) == ["checkout"])
  #expect(controller.panelVisible)
  #expect(controller.handle(.escape))
  #expect(!controller.panelVisible)
  #expect(controller.handle(.escape))
  #expect(controller.panelVisible)
}

@Test("自动单项未选中时Tab一次直接接受唯一候选")
@MainActor
func terminalAutocompleteSingleAutomaticTabAcceptsOnce() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = makeController(fixture)
  defer { controller.invalidate() }
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git chec".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git chec".utf8)[...])
  await Task.yield()
  #expect(controller.panelVisible)
  #expect(controller.currentResult.candidates.map(\.displayText) == ["checkout"])
  #expect(!controller.hasUserSelection)
  #expect(controller.handle(.tab))
  #expect(!controller.panelVisible)
  #expect(sent == Array(repeating: UInt8(127), count: 4) + Array("checkout ".utf8))
  #expect(controller.lastSubmittedCommand == nil)
}

@Test("Agent resume 仅作为实际执行过的历史出现，不注入项目命令")
@MainActor
func terminalAutocompleteUsesRecordedResumeWithoutProjectInjection() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = makeController(fixture)
  let command = "claude --resume sess-42"
  #expect(fixture.service.record(command: command, directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session"))
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)

  controller.receiveInput(Array("cla".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.first?.insertText == command)
  #expect(controller.currentResult.candidates.first?.kind == .learnedCommand)
  #expect(!controller.currentResult.candidates.contains { $0.kind == .snippet })

  fixture.controls.value.autocompleteOnDeviceLearning = false
  controller.refreshNow()
  #expect(!controller.currentResult.candidates.contains { $0.insertText == command })
}

@Test("自动弹出的候选面板在输入退格清空后收起，再输入时重新展开")
@MainActor
func terminalAutocompleteAutoPanelClosesWhenInputIsErased() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteCandidatePanel = .automatic
  let controller = makeController(fixture)
  for command in ["git status", "git commit -m x", "ls"] {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array("\(command)\n".utf8)[...])
    controller.receive(.commandStart)
    controller.receive(.commandFinished(exitStatus: 0))
  }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("g".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)

  // 退格删到空行后候选与面板一起清空。
  controller.receiveInput([0x7F][...])
  controller.refreshNow()
  #expect(controller.currentResult.candidates.isEmpty)
  #expect(!controller.panelVisible)

  controller.receiveInput(Array("l".utf8)[...])
  controller.refreshNow()
  #expect(controller.panelVisible)
}

@Test("仅右箭头模式将Tab放行，无ghost时不自动替用户选择")
@MainActor
func terminalAutocompleteRightArrowModePassesTabThrough() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  fixture.controls.value.autocompleteShortcut = .rightArrow
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
  #expect(controller.panelVisible)
  #expect(!controller.handle(.tab))
  #expect(!controller.hasUserSelection)
  #expect(sent.isEmpty)
  #expect(!controller.handle(.right))
  #expect(!controller.hasUserSelection)
  #expect(sent.isEmpty)
  #expect(controller.handle(.down))
  #expect(!controller.handle(.tab))
  #expect(controller.handle(.right))
  #expect(sent == [127, 127] + Array("checkout ".utf8))

}
