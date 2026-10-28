// 界面扩展测试共用的桩：手动时钟（不真等 30 s）、记录调用的假运行器、视图条目与假视图目录。
import AppKit
import AsterCore
import Combine
import Foundation

@testable import Aster

/// 手动推进的时钟：`sleep` 挂起到 `advance(by:)` 越过截止时刻；Task 取消时抛 `CancellationError`。
@MainActor
final class ManualToolBarClock {
  private struct Sleeper {
    let id: Int
    let deadline: Date
    let continuation: CheckedContinuation<Void, any Error>
  }

  private(set) var now = Date(timeIntervalSince1970: 1_000_000)
  private var sleepers: [Sleeper] = []
  private var nextID = 0

  /// 交给调度器的时钟。
  var clock: ToolBarSchedulerClock {
    ToolBarSchedulerClock(now: { [unowned self] in self.now }, sleep: { [unowned self] in try await self.sleep($0) })
  }

  /// 挂起的 sleep 个数。
  var pendingSleepCount: Int { sleepers.count }

  /// 挂起直到时间推进到 `seconds` 之后。
  func sleep(_ seconds: TimeInterval) async throws {
    nextID += 1
    let id = nextID
    let deadline = now.addingTimeInterval(seconds)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  /// 推进时间，唤醒到点的 sleep，再让出足够多轮让后续工作跑完。
  func advance(by seconds: TimeInterval) async {
    // 先让刚排上的 Task 跑到 sleep，截止时刻才按「现在」登记，推进时间后才会被唤醒。
    await settleToolBarTasks()
    now = now.addingTimeInterval(seconds)
    // 0.1 + 0.2 这类分段推进有浮点误差，按 1 µs 容差判断到点。
    let horizon = now.addingTimeInterval(0.000_001)
    let due = sleepers.filter { $0.deadline <= horizon }
    sleepers.removeAll { $0.deadline <= horizon }
    due.forEach { $0.continuation.resume() }
    await settleToolBarTasks()
  }

  /// 取消一个 sleep。
  private func cancel(_ id: Int) {
    guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
    sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

/// 让主线程上排队的 Task 都跑一跑。
@MainActor
func settleToolBarTasks() async {
  for _ in 0..<200 { await Task.yield() }
}

/// 记录每次运行的假运行器；`handler` 决定返回什么。
@MainActor
final class RecordingToolBarRunner {
  private(set) var requests: [ToolBarRunRequest] = []
  /// 被取消（运行时收到 CancellationError）的次数。
  private(set) var cancellations = 0
  var handler: @MainActor (ToolBarRunRequest) async throws -> ToolBarOutput = { _ in
    ToolBarOutput(items: [ToolBarItem(text: "ok")])
  }

  var runner: ToolBarRunner {
    { [unowned self] request in
      self.requests.append(request)
      do {
        return try await self.handler(request)
      } catch is CancellationError {
        self.cancellations += 1
        throw CancellationError()
      }
    }
  }

  var triggers: [ToolBarTrigger] { requests.map(\.trigger) }
}

/// 测试用的 bar / panel 视图条目。
func makeToolViewEntry(
  pluginID: String = "test.plugin",
  pluginName: String = "Test",
  viewID: String = "bar",
  kind: ToolViewKind = .bar,
  slot: ToolViewSlot = .tabBottom,
  interval: Int? = 30,
  triggers: [ToolViewRefreshTrigger]? = nil,
  status: ToolPluginStatus = .ready,
  source: ToolPluginSource = .user,
  isEnabled: Bool = true,
  permissions: Set<ToolPermission> = []
) -> ToolViewEntry {
  let contribution = ToolViewContribution(
    id: viewID, title: viewID, kind: kind, slot: slot,
    source: kind == .bar ? ToolViewScriptSource(command: ["bin/bar.sh"]) : nil,
    refresh: kind == .bar ? ToolViewRefresh(interval: interval, on: triggers) : nil,
    main: kind == .panel ? "views/\(viewID).html" : nil)
  return ToolViewEntry(
    pluginID: pluginID, pluginName: pluginName, source: source, contribution: contribution, slot: slot,
    isEnabled: isEnabled, status: status, iconPath: nil, pluginDirectory: URL(fileURLWithPath: "/tmp/\(pluginID)"),
    permissions: permissions)
}

/// 假视图目录：测试直接改 `viewEntries` 再 `send()`。
@MainActor
final class FakeToolViewCatalog: ToolViewCatalog {
  var viewEntries: [ToolViewEntry] = []
  var features: [String: ToolCatalogEntry] = [:]
  private(set) var approvals: [String] = []
  private let subject = PassthroughSubject<Void, Never>()

  var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

  func entry(id: String) -> ToolCatalogEntry? { features[id] }

  func approve(pluginID: String, window: NSWindow?) async -> Bool {
    approvals.append(pluginID)
    return true
  }

  /// 发一次目录变化。
  func send() { subject.send() }
}
