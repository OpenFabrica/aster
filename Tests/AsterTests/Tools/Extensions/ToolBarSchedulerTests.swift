// bar 调度：首次运行与定时自续、上下文触发去抖与最短间隔、缓存命中不重跑、不可见暂停与恢复补跑、
// 连续失败退避、关窗取消运行中的脚本、并发上限。时钟是手动的，不真等。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：bar 调度")
struct ToolBarSchedulerTests {
  private struct Failure: Error {}

  private func makeScheduler(
    _ runner: RecordingToolBarRunner, _ clock: ManualToolBarClock, context: ToolBarContext = ToolBarContext(
      workingDirectory: "/repo/a")
  ) -> ToolBarScheduler {
    ToolBarScheduler(context: context, isVisible: true, runner: runner.runner, clock: clock.clock)
  }

  @Test("挂载后去抖 300 ms 跑一次 initial；之后按 interval 单次 sleep 自续")
  func initialRunThenIntervalReschedules() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    let entry = makeToolViewEntry(interval: 30)
    scheduler.update(entries: [entry])
    await clock.advance(by: 0.1)
    #expect(runner.requests.isEmpty)
    await clock.advance(by: 0.2)
    #expect(runner.triggers == [.initial])
    #expect(runner.requests.first?.context.workingDirectory == "/repo/a")
    guard case .ready(let items, _)? = scheduler.feed(id: entry.id)?.state else {
      Issue.record("没有进入 ready")
      return
    }
    #expect(items.map(\.text) == ["ok"])
    await clock.advance(by: 29)
    #expect(runner.requests.count == 1)
    await clock.advance(by: 1)
    #expect(runner.triggers == [.initial, .interval])
    await clock.advance(by: 30)
    #expect(runner.triggers == [.initial, .interval, .interval])
  }

  @Test("脚本给的 ttl 覆盖下一次间隔")
  func ttlOverridesInterval() async {
    let runner = RecordingToolBarRunner()
    runner.handler = { _ in ToolBarOutput(items: [ToolBarItem(text: "x")], ttl: 600) }
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    scheduler.update(entries: [makeToolViewEntry(interval: 30)])
    await clock.advance(by: 0.3)
    await clock.advance(by: 300)
    #expect(runner.requests.count == 1)
    await clock.advance(by: 300)
    #expect(runner.triggers == [.initial, .interval])
  }

  @Test("连续换目录在 300 ms 内合并成一次、用最后的上下文；失败结果来回切换受 5 s 最短间隔约束")
  func contextTriggersDebounceAndRespectMinimumInterval() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    scheduler.update(entries: [makeToolViewEntry(interval: 0)])
    await clock.advance(by: 0.3)
    #expect(runner.triggers == [.initial])

    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/b"))
    await clock.advance(by: 0.1)
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/c"))
    await clock.advance(by: 0.2)
    #expect(runner.requests.count == 1)
    await clock.advance(by: 0.1)
    #expect(runner.triggers == [.initial, .cwd])
    #expect(runner.requests.last?.context.workingDirectory == "/repo/c")

    // 失败结果不入缓存：在 d 失败后切走再切回，5 s 内不再拉起脚本，到点才补跑。
    runner.handler = { _ in throw Failure() }
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/d"))
    await clock.advance(by: 0.3)
    #expect(runner.requests.count == 3)
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/c"))
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/d"))
    await clock.advance(by: 0.3)
    #expect(runner.requests.count == 3)
    // 上一次在 d 开始运行是 0.3 s 前，最早 4.7 s 后才能再跑。
    await clock.advance(by: 4.6)
    #expect(runner.requests.count == 3)
    await clock.advance(by: 0.1)
    #expect(runner.requests.count == 4)
    #expect(runner.requests.last?.context.workingDirectory == "/repo/d")
  }

  @Test("上下文键没变（或只变了没声明的字段）不重跑；切回旧上下文命中缓存直接显示")
  func sameContextKeyAfterRefreshDoesNotRerun() async {
    let runner = RecordingToolBarRunner()
    runner.handler = { request in ToolBarOutput(items: [ToolBarItem(text: request.context.workingDirectory)]) }
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    let entry = makeToolViewEntry(interval: 0, triggers: [.cwd])
    scheduler.update(entries: [entry])
    await clock.advance(by: 0.3)
    #expect(runner.requests.count == 1)

    // 只换了 Pane（视图没声明 activePane）：不算变化。
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/a", paneID: "p2"))
    await clock.advance(by: 1)
    #expect(runner.requests.count == 1)

    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/b"))
    await clock.advance(by: 0.3)
    #expect(runner.requests.count == 2)
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/a"))
    await clock.advance(by: 1)
    #expect(runner.requests.count == 2)
    guard case .ready(let items, _)? = scheduler.feed(id: entry.id)?.state else {
      Issue.record("没有显示缓存")
      return
    }
    #expect(items.first?.text == "/repo/a")
  }

  @Test("窗口不可见时不跑、不留定时，触发只记 stale；恢复可见立即补跑一次")
  func hiddenWindowPausesAndStaleFeedRunsOnReveal() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    scheduler.update(entries: [makeToolViewEntry(interval: 30)])
    await clock.advance(by: 0.3)
    #expect(runner.requests.count == 1)

    scheduler.isVisible = false
    await settleToolBarTasks()
    #expect(clock.pendingSleepCount == 0)
    await clock.advance(by: 120)
    scheduler.updateContext(ToolBarContext(workingDirectory: "/repo/b"))
    await clock.advance(by: 1)
    #expect(runner.requests.count == 1)

    scheduler.isVisible = true
    await settleToolBarTasks()
    #expect(runner.requests.count == 2)
    #expect(runner.requests.last?.trigger == .cwd)
    #expect(runner.requests.last?.context.workingDirectory == "/repo/b")

    // 没有 stale、只是定时过期：恢复时同样立即跑。
    scheduler.isVisible = false
    await clock.advance(by: 45)
    scheduler.isVisible = true
    await settleToolBarTasks()
    #expect(runner.triggers.last == .interval)
    #expect(runner.requests.count == 3)
  }

  @Test("连续 3 次失败后退避到 max(interval × 4, 300) 秒；成功后恢复原间隔")
  func consecutiveFailuresBackOff() async {
    let runner = RecordingToolBarRunner()
    runner.handler = { _ in throw Failure() }
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    let entry = makeToolViewEntry(interval: 30)
    scheduler.update(entries: [entry])
    await clock.advance(by: 0.3)
    await clock.advance(by: 30)
    await clock.advance(by: 30)
    #expect(runner.requests.count == 3)
    #expect(scheduler.feed(id: entry.id)?.consecutiveFailures == 3)
    guard case .failed? = scheduler.feed(id: entry.id)?.state else {
      Issue.record("没有进入失败态")
      return
    }
    await clock.advance(by: 30)
    #expect(runner.requests.count == 3)
    await clock.advance(by: 269)
    #expect(runner.requests.count == 3)
    runner.handler = { _ in ToolBarOutput(items: [ToolBarItem(text: "ok")]) }
    await clock.advance(by: 1)
    #expect(runner.requests.count == 4)
    #expect(scheduler.feed(id: entry.id)?.consecutiveFailures == 0)
    await clock.advance(by: 30)
    #expect(runner.requests.count == 5)
  }

  @Test("关窗 teardown 取消正在运行的脚本，之后不再有任何运行")
  func teardownCancelsRunningScript() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    runner.handler = { _ in
      try await clock.sleep(1_000)
      return ToolBarOutput()
    }
    let scheduler = makeScheduler(runner, clock)
    let entry = makeToolViewEntry(interval: 30)
    scheduler.update(entries: [entry])
    await clock.advance(by: 0.3)
    #expect(scheduler.runningCount == 1)
    #expect(scheduler.feed(id: entry.id)?.runningSince != nil)

    scheduler.teardown()
    await settleToolBarTasks()
    #expect(runner.cancellations == 1)
    #expect(scheduler.runningCount == 0)
    #expect(clock.pendingSleepCount == 0)
    scheduler.update(entries: [entry])
    scheduler.refresh(entryID: entry.id)
    await clock.advance(by: 60)
    #expect(runner.requests.count == 1)
  }

  @Test("每插件同时最多 2 个脚本，每窗口最多 4 个；跑完的让出名额")
  func concurrencyIsCappedPerPluginAndWindow() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    runner.handler = { _ in
      try await clock.sleep(10)
      return ToolBarOutput()
    }
    let scheduler = makeScheduler(runner, clock)
    let entries =
      (0..<3).map { makeToolViewEntry(pluginID: "one", viewID: "v\($0)", interval: 0) }
      + (0..<3).map { makeToolViewEntry(pluginID: "two", viewID: "v\($0)", interval: 0) }
      + [makeToolViewEntry(pluginID: "three", viewID: "v0", interval: 0)]
    scheduler.update(entries: entries)
    await clock.advance(by: 0.3)
    #expect(scheduler.runningCount == 4)
    #expect(Set(runner.requests.map(\.pluginID)) == ["one", "two"])
    await clock.advance(by: 10)
    #expect(runner.requests.count == 7)
    await clock.advance(by: 10)
    #expect(scheduler.runningCount == 0)
  }

  @Test("pane feed 各用自己 Pane 的上下文；后台标签的 Pane 暂停（触发只记 stale、不留定时），切回来立即补跑")
  func backgroundTabPaneFeedsPauseAndResumeOnReturn() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    let entry = makeToolViewEntry(slot: .paneBottom, interval: 30)
    let paneA = UUID()
    let paneB = UUID()
    let keyA = ToolBarScheduler.paneFeedKey(entryID: entry.id, paneID: paneA)
    let keyB = ToolBarScheduler.paneFeedKey(entryID: entry.id, paneID: paneB)
    scheduler.setVisiblePanes([paneA, paneB])
    scheduler.update(specs: [
      ToolBarFeedSpec(key: keyA, entry: entry, paneID: paneA, context: ToolBarContext(workingDirectory: "/pane/a")),
      ToolBarFeedSpec(key: keyB, entry: entry, paneID: paneB, context: ToolBarContext(workingDirectory: "/pane/b")),
    ])
    await clock.advance(by: 0.3)
    #expect(Set(runner.requests.map { $0.context.workingDirectory ?? "" }) == ["/pane/a", "/pane/b"])

    // 标签范围的上下文变化不碰 pane feed。
    scheduler.updateContext(ToolBarContext(workingDirectory: "/tab/elsewhere"))
    await clock.advance(by: 1)
    #expect(runner.requests.count == 2)

    // B 所在标签切到后台：B 的目录变化与定时都不跑，A 照常定时。
    scheduler.setVisiblePanes([paneA])
    scheduler.updatePaneContext(ToolBarContext(workingDirectory: "/pane/b2"), paneID: paneB)
    // 首次运行后已经过了 1 s，再 28 s 还没到 A 的 30 s 定时。
    await clock.advance(by: 28)
    #expect(runner.requests.count == 2)
    await clock.advance(by: 1)
    #expect(runner.requests.count == 3)
    #expect(runner.requests.last?.context.workingDirectory == "/pane/a")
    await clock.advance(by: 120)
    #expect(runner.requests.allSatisfy { $0.context.workingDirectory != "/pane/b2" })

    // 切回来：B 立即按 stale 的 cwd 触发补跑，用它自己的新目录。
    let before = runner.requests.count
    scheduler.setVisiblePanes([paneA, paneB])
    await settleToolBarTasks()
    #expect(runner.requests.count == before + 1)
    #expect(runner.requests.last?.trigger == .cwd)
    #expect(runner.requests.last?.context.workingDirectory == "/pane/b2")

    // Pane 关闭：feed 被取消，不再运行。
    scheduler.update(specs: [
      ToolBarFeedSpec(key: keyA, entry: entry, paneID: paneA, context: ToolBarContext(workingDirectory: "/pane/a"))
    ])
    #expect(scheduler.feed(id: keyB) == nil)
  }

  @Test("需要授权的视图不跑脚本；授权后（状态变成 ready）按 manual 跑一次")
  func needsApprovalWaitsForApproval() async {
    let runner = RecordingToolBarRunner()
    let clock = ManualToolBarClock()
    let scheduler = makeScheduler(runner, clock)
    let pending = makeToolViewEntry(status: .needsApproval(.firstRun))
    scheduler.update(entries: [pending])
    await clock.advance(by: 1)
    #expect(runner.requests.isEmpty)
    #expect(scheduler.feed(id: pending.id)?.state == .needsApproval)
    scheduler.update(entries: [makeToolViewEntry(status: .ready)])
    await clock.advance(by: 0.3)
    #expect(runner.triggers == [.manual])
  }
}
