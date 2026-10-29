// Files 预览协调器：过期结果作废、长按节流、缓存复用与失效、取消和固定。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 记录假 loader 被调用的文件，跨隔离安全计数。
private actor PreviewLoadLog {
  private(set) var names: [String] = []

  /// 记一次读取。
  func record(_ url: URL) { names.append(url.lastPathComponent) }

  /// 某个文件被读取的次数。
  func count(_ name: String) -> Int { names.filter { $0 == name }.count }
}

/// 协调器夹具：隔离偏好的模型、临时文件和带计数 loader 的协调器；`slow.txt` 读取慢 300ms。
@MainActor
private struct CoordinatorFixture {
  let root: URL
  let model: AppModel
  let log = PreviewLoadLog()
  let coordinator: DetailsFilesPreviewCoordinator

  init(repeatThrottle: Duration = .milliseconds(120)) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-preview-coordinator-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["a.txt", "b.txt", "c.txt", "slow.txt", "fast.txt", "pin.swift"] {
      try Data("\(name)\n".utf8).write(to: root.appendingPathComponent(name))
    }
    let defaults = UserDefaults(suiteName: "DetailsFilesPreviewCoordinatorTests.\(UUID().uuidString)")!
    model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    let log = log
    coordinator = DetailsFilesPreviewCoordinator(
      model: model,
      loader: { url, provider in
        await log.record(url)
        if url.lastPathComponent == "slow.txt" {
          // 分离任务不继承取消，模拟真实后台读取在请求作废后仍然返回。
          await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
        }
        return FileDocumentPreload.load(url, trustedAgentProvider: provider)
      },
      repeatThrottle: repeatThrottle,
      isMousePressed: { false })
  }

  /// 夹具目录下某个文件的 URL。
  func url(_ name: String) -> URL { root.appendingPathComponent(name).standardizedFileURL }

  /// 以指定来源选中文件。
  func select(_ name: String, _ trigger: DetailsFilesPreviewCoordinator.Trigger = .click) {
    coordinator.selectionChanged(to: url(name), browsingRoot: root.path, trigger: trigger)
  }

  /// 停掉标签运行态并删除临时目录。
  func tearDown() {
    coordinator.cancel()
    model.selectedTab?.stop(immediately: true)
    try? FileManager.default.removeItem(at: root)
  }
}

@Test("连续快速选中只提交最后一项，前面的请求不读盘")
@MainActor
func coordinatorCommitsOnlyLatestOfRapidSelections() async throws {
  let fixture = try CoordinatorFixture()
  defer { fixture.tearDown() }
  let tab = try #require(fixture.model.selectedTab)
  let panesBefore = tab.layout.allPanes.count
  fixture.select("a.txt", .key(isRepeat: false))
  fixture.select("b.txt", .key(isRepeat: true))
  fixture.select("c.txt", .key(isRepeat: true))
  await fixture.coordinator.pendingTask?.value
  #expect(tab.previewSlotFileURL == fixture.url("c.txt"))
  #expect(tab.layout.allPanes.count == panesBefore + 1)
  #expect(await fixture.log.names == ["c.txt"])
}

@Test("迟到的旧预读结果被丢弃，不覆盖新选中的文件")
@MainActor
func coordinatorDropsStaleSlowResult() async throws {
  let fixture = try CoordinatorFixture()
  defer { fixture.tearDown() }
  let tab = try #require(fixture.model.selectedTab)
  fixture.select("slow.txt")
  let slowTask = fixture.coordinator.pendingTask
  for _ in 0..<200 where await fixture.log.count("slow.txt") == 0 {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(await fixture.log.count("slow.txt") == 1)
  fixture.select("fast.txt")
  await fixture.coordinator.pendingTask?.value
  #expect(tab.previewSlotFileURL == fixture.url("fast.txt"))
  await slowTask?.value
  #expect(tab.previewSlotFileURL == fixture.url("fast.txt"))
}

@Test("长按方向键在节流间隔内延后提交，但最终显示最新项")
@MainActor
func coordinatorThrottlesKeyRepeat() async throws {
  let fixture = try CoordinatorFixture(repeatThrottle: .milliseconds(250))
  defer { fixture.tearDown() }
  let tab = try #require(fixture.model.selectedTab)
  fixture.select("a.txt", .key(isRepeat: false))
  await fixture.coordinator.pendingTask?.value
  let start = ContinuousClock.now
  fixture.select("b.txt", .key(isRepeat: true))
  for _ in 0..<5 { await Task.yield() }
  #expect(tab.previewSlotFileURL == fixture.url("a.txt"))
  await fixture.coordinator.pendingTask?.value
  #expect(tab.previewSlotFileURL == fixture.url("b.txt"))
  #expect(ContinuousClock.now - start >= .milliseconds(150))
}

@Test("缓存命中时不再读盘，文件变化后重新读取")
@MainActor
func coordinatorCacheReusesUnchangedFiles() async throws {
  let fixture = try CoordinatorFixture()
  defer { fixture.tearDown() }
  let tab = try #require(fixture.model.selectedTab)
  for name in ["a.txt", "b.txt", "a.txt"] {
    fixture.select(name)
    await fixture.coordinator.pendingTask?.value
  }
  #expect(await fixture.log.count("a.txt") == 1)
  #expect(tab.previewSlotFileURL == fixture.url("a.txt"))
  try Data("a.txt changed and longer\n".utf8).write(to: fixture.url("a.txt"))
  for name in ["b.txt", "a.txt"] {
    fixture.select(name)
    await fixture.coordinator.pendingTask?.value
  }
  #expect(await fixture.log.count("a.txt") == 2)
  let slotID = try #require(tab.validPreviewSlotPaneID())
  #expect(tab.runtime(for: slotID)?.documentText == "a.txt changed and longer\n")
}

@Test("cancel 之后进行中的请求不再提交")
@MainActor
func coordinatorCancelPreventsCommit() async throws {
  let fixture = try CoordinatorFixture()
  defer { fixture.tearDown() }
  let tab = try #require(fixture.model.selectedTab)
  let panesBefore = tab.layout.allPanes.count
  fixture.select("slow.txt")
  let pending = fixture.coordinator.pendingTask
  fixture.coordinator.cancel()
  #expect(fixture.coordinator.pendingTask == nil)
  await pending?.value
  #expect(tab.previewSlotFileURL == nil)
  #expect(tab.layout.allPanes.count == panesBefore)
}

@Test("固定没有在槽里的文件：先放进槽再固定并聚焦，解锁可编辑类型")
@MainActor
func coordinatorPinCreatesSlotThenPins() async throws {
  let fixture = try CoordinatorFixture()
  defer { fixture.tearDown() }
  let tab = try #require(fixture.model.selectedTab)
  let panesBefore = tab.layout.allPanes.count
  fixture.coordinator.pin(fixture.url("pin.swift"), browsingRoot: fixture.root.path)
  await fixture.coordinator.pendingTask?.value
  #expect(tab.layout.allPanes.count == panesBefore + 1)
  #expect(tab.previewSlotPaneID == nil)
  let active = try #require(tab.activeRuntime)
  #expect(active.descriptor.resourcePath == fixture.url("pin.swift").path)
  #expect(active.isReadOnly == false)
}
