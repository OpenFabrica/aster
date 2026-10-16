import Foundation
import Testing

@testable import AsterCore

private let nonce = "00aa11bb22cc"
private let start = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("agent 命令跟踪与等输入判断")
struct AgentHostCommandTrackerTests {
  @Test("看到结束标记即完成，结果进历史")
  func completes() {
    var tracker = AgentHostCommandTracker()
    tracker.start(id: "c-1", nonce: nonce, command: "ls", at: start)
    #expect(tracker.observe(screen: "$ ls", now: start, scrollback: { nil }) == nil)
    let screen = "$ ls\n<aster:\(nonce)b>\na\nb\n<aster:\(nonce)e:0>\n$"
    guard case .finished(let result)? = tracker.observe(screen: screen, now: start.addingTimeInterval(1), scrollback: { nil })
    else {
      Issue.record("应完成")
      return
    }
    #expect(result.output == "a\nb")
    #expect(result.exitCode == 0)
    #expect(result.durationMs == 1_000)
    #expect(tracker.running == nil)
    #expect(tracker.finishedCommand("c-1") == result)
  }

  @Test("开始标记滚出活动屏幕时从回滚补全输出")
  func usesScrollbackWhenBeginScrolledOut() {
    var tracker = AgentHostCommandTracker()
    tracker.start(id: "c-1", nonce: nonce, command: "seq", at: start)
    let active = "99\n100\n<aster:\(nonce)e:0>\n$"
    let full = "<aster:\(nonce)b>\n1\n" + active
    guard case .finished(let result)? = tracker.observe(screen: active, now: start, scrollback: { full }) else {
      Issue.record("应完成")
      return
    }
    #expect(result.output == "1\n99\n100")
    #expect(!result.outputTruncated)
  }

  @Test("屏幕静止 2 秒且最后一行像提示才算等输入；屏幕再变化即恢复")
  func needsInputAndResume() {
    var tracker = AgentHostCommandTracker(needsInputQuiet: 2)
    tracker.start(id: "c-1", nonce: nonce, command: "sudo ls", at: start)
    let prompt = "<aster:\(nonce)b>\n[sudo] password for deploy:"
    #expect(tracker.observe(screen: prompt, now: start, scrollback: { nil }) == nil)
    #expect(tracker.observe(screen: prompt, now: start.addingTimeInterval(1), scrollback: { nil }) == nil)
    #expect(
      tracker.observe(screen: prompt, now: start.addingTimeInterval(2.1), scrollback: { nil })
        == .needsInput(prompt: "[sudo] password for deploy:"))
    #expect(tracker.running?.needsInputEpisode == 1)
    // 同一提示不重复上报。
    #expect(tracker.observe(screen: prompt, now: start.addingTimeInterval(5), scrollback: { nil }) == nil)
    #expect(tracker.observe(screen: prompt + "\nfile", now: start.addingTimeInterval(6), scrollback: { nil }) == .resumed)
    #expect(tracker.running?.prompt == nil)
  }

  @Test("普通静默输出不算等输入；开始标记前不判断")
  func quietOutputIsNotPrompt() {
    var tracker = AgentHostCommandTracker(needsInputQuiet: 2)
    tracker.start(id: "c-1", nonce: nonce, command: "sleep 9", at: start)
    let screen = "<aster:\(nonce)b>\nworking 50%"
    _ = tracker.observe(screen: screen, now: start, scrollback: { nil })
    #expect(tracker.observe(screen: screen, now: start.addingTimeInterval(10), scrollback: { nil }) == nil)
    var early = AgentHostCommandTracker(needsInputQuiet: 2)
    early.start(id: "c-2", nonce: nonce, command: "x", at: start)
    _ = early.observe(screen: "Password:", now: start, scrollback: { nil })
    #expect(early.observe(screen: "Password:", now: start.addingTimeInterval(10), scrollback: { nil }) == nil)
  }

  @Test("中断：宽限期内见结束标记按完成；否则记 interrupted 且无退出码")
  func interrupt() {
    var tracker = AgentHostCommandTracker(interruptGrace: 1.5)
    tracker.start(id: "c-1", nonce: nonce, command: "sleep 99", at: start)
    let screen = "<aster:\(nonce)b>\npartial\n^C"
    tracker.requestInterrupt(at: start)
    #expect(tracker.observe(screen: screen, now: start.addingTimeInterval(1), scrollback: { nil }) == nil)
    guard case .finished(let result)? = tracker.observe(screen: screen, now: start.addingTimeInterval(2), scrollback: { screen })
    else {
      Issue.record("宽限期后应记 interrupted")
      return
    }
    #expect(result.status == .interrupted)
    #expect(result.exitCode == nil)
    #expect(result.output == "partial\n^C")
  }

  @Test("终端结束：运行中命令记 ended；历史有上限")
  func endedAndHistoryLimit() {
    var tracker = AgentHostCommandTracker()
    #expect(tracker.end(at: start, scrollback: nil) == nil)
    for index in 0..<(AgentHostCommandTracker.finishedHistoryLimit + 3) {
      tracker.start(id: "c-\(index)", nonce: nonce, command: "x", at: start)
      _ = tracker.end(at: start, scrollback: "<aster:\(nonce)b>\nout")
    }
    #expect(tracker.finished.count == AgentHostCommandTracker.finishedHistoryLimit)
    #expect(tracker.finishedCommand("c-0") == nil)
    #expect(tracker.finished.last?.status == .ended)
    #expect(tracker.finished.last?.output == "out")
  }
}

@Suite("等输入提示的启发式")
struct AgentHostPromptHeuristicsTests {
  @Test(
    "像提示的最后一行",
    arguments: [
      "[sudo] password for deploy:", "Password:", "Enter passphrase for key '/x':", "Are you sure (yes/no/[fingerprint])?",
      "Do you want to continue? [Y/n]", "Proceed [y/N]", "--More--", "(END)", ":", "Press ENTER to continue",
      "Name of the project:",
    ])
  func prompts(line: String) {
    #expect(AgentHostPromptHeuristics.prompt(in: "output\n\(line)\n\n") == line)
  }

  @Test("普通输出不是提示", arguments: ["building 3/10", "done.", "total 42", ""])
  func nonPrompts(line: String) {
    #expect(AgentHostPromptHeuristics.prompt(in: "x\n\(line)") == nil)
  }
}
