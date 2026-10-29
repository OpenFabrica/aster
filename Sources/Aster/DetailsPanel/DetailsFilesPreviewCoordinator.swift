// Files 选中 → 预览槽的调度：后台预读、长按节流、过期结果作废与小型 LRU 缓存。
// 目标是 yazi 式手感：单击或单次按键立即预览，按住 ↓ 时预览跟着滚动但不堆积任务。
import AppKit
import AsterCore

@MainActor
final class DetailsFilesPreviewCoordinator {
  /// 选中变化的来源，决定是否节流。
  enum Trigger: Equatable {
    case click
    case key(isRepeat: Bool)
  }

  /// 后台预读入口；测试可注入假实现。默认在分离任务中执行 `FileDocumentPreload.load`。
  typealias Loader = @Sendable (URL, AgentProvider?) async -> FileDocumentPreload?

  private let model: AppModel
  private let loader: Loader
  private let repeatThrottle: Duration
  private let cacheCapacity: Int
  private let cacheByteBudget: Int
  private let isMousePressed: @MainActor () -> Bool
  private let clock = ContinuousClock()
  /// 每次选中变化加一；只有最新一代的预读结果才写进预览槽。
  private var generation = 0
  private var task: Task<Void, Never>?
  private var lastCommit: ContinuousClock.Instant?
  /// LRU：数组尾部是最近使用。条目很少（默认 12），线性查找足够。
  private var cache: [FileDocumentPreload] = []

  init(
    model: AppModel,
    loader: @escaping Loader = { url, provider in
      await Task.detached(priority: .userInitiated) {
        FileDocumentPreload.load(url, trustedAgentProvider: provider)
      }.value
    },
    repeatThrottle: Duration = .milliseconds(120),
    cacheCapacity: Int = 12,
    cacheByteBudget: Int = 16 * 1_024 * 1_024,
    isMousePressed: @escaping @MainActor () -> Bool = { NSEvent.pressedMouseButtons != 0 }
  ) {
    self.model = model
    self.loader = loader
    self.repeatThrottle = repeatThrottle
    self.cacheCapacity = cacheCapacity
    self.cacheByteBudget = cacheByteBudget
    self.isMousePressed = isMousePressed
  }

  isolated deinit { task?.cancel() }

  /// 正在进行的预读或等待中的节流任务；测试用来等待提交完成。
  var pendingTask: Task<Void, Never>? { task }

  /// Files 选中行变化。`url` 为 nil（目录、未选中）时只作废旧请求，预览槽保持原样。
  func selectionChanged(to url: URL?, browsingRoot: String?, trigger: Trigger) {
    generation += 1
    task?.cancel()
    task = nil
    guard let url, let browsingRoot, let tab = model.selectedTab else { return }
    let request = generation
    // 长按方向键时最多每 `repeatThrottle` 提交一次；单击与单次按键不等待。
    var delay: Duration = .zero
    if trigger == .key(isRepeat: true), let lastCommit {
      let elapsed = clock.now - lastCommit
      if elapsed < repeatThrottle { delay = repeatThrottle - elapsed }
    }
    task = Task { [weak self, weak tab] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      guard let self, let tab, !Task.isCancelled, request == self.generation else { return }
      guard let preload = await self.preload(url) else { return }
      guard !Task.isCancelled, request == self.generation, self.model.selectedTab === tab else {
        return
      }
      await self.waitForMouseReleaseIfCreatingSlot(in: tab)
      guard !Task.isCancelled, request == self.generation, self.model.selectedTab === tab else {
        return
      }
      tab.showInPreviewSlot(preload, browsingRoot: browsingRoot)
      self.lastCommit = self.clock.now
    }
  }

  /// Enter / 双击：固定该文件。预览槽已经显示它就原地固定；否则先放进预览槽再固定，
  /// 保证双击的第一下预览和第二下固定落在同一个 Pane，而不是多拆一个分屏。
  /// 固定后聚焦该 Pane，与「打开」的预期一致。
  func pin(_ url: URL, browsingRoot: String?) {
    generation += 1
    task?.cancel()
    let request = generation
    let target = url.standardizedFileURL
    guard let tab = model.selectedTab else { return }
    if tab.previewSlotFileURL == target {
      commitPin(in: tab, url: target)
      return
    }
    // 别的 Pane 已打开同一文件时直接聚焦它，不再另开一份。
    if let existing = tab.layout.allPanes.first(where: { pane in
      [.editor, .preview].contains(pane.kind)
        && pane.resourcePath.map { URL(fileURLWithPath: $0).standardizedFileURL } == target
    }) {
      tab.setActivePane(existing.id)
      return
    }
    guard let browsingRoot, tab.remoteTabID == nil else {
      model.openResource(target, mode: .automatic, placement: .split(.right))
      return
    }
    task = Task { [weak self, weak tab] in
      guard let self, let tab, let preload = await self.preload(target) else { return }
      guard !Task.isCancelled, request == self.generation, self.model.selectedTab === tab else {
        return
      }
      tab.showInPreviewSlot(preload, browsingRoot: browsingRoot)
      self.commitPin(in: tab, url: target)
    }
  }

  /// 作废进行中的请求；Files 页隐藏、切换 Pane 或面板销毁时调用。
  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
  }

  /// 预览槽显示的正是 `url` 时固定并聚焦它；否则回退到普通打开。
  private func commitPin(in tab: TerminalTabItem, url: URL) {
    guard tab.previewSlotFileURL == url, let paneID = tab.pinPreviewSlot() else {
      model.openResource(url, mode: .automatic, placement: .split(.right))
      return
    }
    tab.setActivePane(paneID)
  }

  /// 第一次建预览槽会整树重建；鼠标仍按着时重建会让按下的视图收不到 mouseUp，
  /// 所以等松开后再提交。已有槽时只原地换内容，不受影响。
  private func waitForMouseReleaseIfCreatingSlot(in tab: TerminalTabItem) async {
    guard tab.validPreviewSlotPaneID() == nil else { return }
    var waited = 0
    while isMousePressed(), waited < 100, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(20))
      waited += 1
    }
  }

  /// 取预读结果：缓存命中且文件的修改时间和大小未变时直接复用，否则后台重读。
  private func preload(_ url: URL) async -> FileDocumentPreload? {
    let target = url.standardizedFileURL
    if let index = cache.firstIndex(where: { $0.url == target }) {
      let cached = cache.remove(at: index)
      let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
      if attributes?[.modificationDate] as? Date == cached.modificationDate,
        (attributes?[.size] as? NSNumber)?.intValue == cached.fileSize
      {
        cache.append(cached)
        return cached
      }
    }
    let provider = model.agentHistories.first(where: {
      $0.metadata.transcriptFileURL.standardizedFileURL == target
    })?.metadata.configuration.provider
    guard let loaded = await loader(target, provider) else { return nil }
    remember(loaded)
    return loaded
  }

  /// 写入 LRU；按条目数和文本总字节两个上限淘汰最久未用的条目。
  private func remember(_ preload: FileDocumentPreload) {
    let size = Self.textBytes(of: preload)
    guard size <= cacheByteBudget else { return }
    cache.removeAll { $0.url == preload.url }
    cache.append(preload)
    var total = cache.reduce(0) { $0 + Self.textBytes(of: $1) }
    while cache.count > cacheCapacity || total > cacheByteBudget {
      total -= Self.textBytes(of: cache.removeFirst())
    }
  }

  private static func textBytes(of preload: FileDocumentPreload) -> Int {
    guard case .success(let buffer) = preload.document else { return 0 }
    return buffer.text.utf8.count
  }
}
