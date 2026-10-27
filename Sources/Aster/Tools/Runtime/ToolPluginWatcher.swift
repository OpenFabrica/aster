// 插件目录监听：用户插件目录与每个开发目录各挂一个 vnode 监听（只看一层），开发目录再加 1 s 修改时间轮询兜底
// （vnode 收不到子目录里或原地改写的文件内容）。变化合并去抖后通知工具中心重新扫描。
import AsterCore
import Foundation

/// 监听插件目录变化。只在主线程使用；指纹计算在后台进行。
@MainActor
final class ToolPluginWatcher {
  /// 变化回调：参数是内容发生变化的开发目录（只有用户插件目录变化时为空集合）。
  var onChange: (@MainActor (_ changedDevelopmentFolders: Set<String>) -> Void)?

  private let pollInterval: Duration
  private let debounce: Duration
  private var userWatcher: FileSystemDirectoryWatcher?
  private var userDirectory: URL?
  private var developmentWatchers: [String: FileSystemDirectoryWatcher] = [:]
  private var developmentFolders: [String] = []
  private var fingerprints: [String: Int?] = [:]
  private var pollTask: Task<Void, Never>?
  private var pendingFolders: Set<String> = []
  private var hasPendingChange = false
  private var debounceTask: Task<Void, Never>?

  init(pollInterval: Duration = .seconds(1), debounce: Duration = .milliseconds(150)) {
    self.pollInterval = pollInterval
    self.debounce = debounce
  }

  /// 按当前位置调整监听：新目录挂上、移除的目录摘掉；有开发目录时才轮询。目录不存在时跳过（下次配置再试）。
  func configure(userDirectory: URL, developmentFolders: [String]) {
    if self.userDirectory != userDirectory || userWatcher?.isWatching != true {
      userWatcher?.stop()
      userWatcher = startWatcher(userDirectory) { [weak self] in self?.noteChange(folder: nil) }
      self.userDirectory = userDirectory
    }
    for (path, watcher) in developmentWatchers where !developmentFolders.contains(path) {
      watcher.stop()
      developmentWatchers[path] = nil
      fingerprints[path] = nil
    }
    for path in developmentFolders where developmentWatchers[path] == nil {
      developmentWatchers[path] = startWatcher(URL(fileURLWithPath: path, isDirectory: true)) { [weak self] in
        self?.noteChange(folder: path)
      }
    }
    self.developmentFolders = developmentFolders
    if developmentFolders.isEmpty {
      pollTask?.cancel()
      pollTask = nil
    } else if pollTask == nil {
      startPolling()
    }
  }

  /// 停止全部监听与轮询。
  func stop() {
    userWatcher?.stop()
    userWatcher = nil
    developmentWatchers.values.forEach { $0.stop() }
    developmentWatchers = [:]
    pollTask?.cancel()
    pollTask = nil
    debounceTask?.cancel()
    debounceTask = nil
  }

  /// 挂一个目录监听；目录不存在或打不开时返回 nil。
  private func startWatcher(
    _ directory: URL, onChange: @escaping @MainActor @Sendable () -> Void
  ) -> FileSystemDirectoryWatcher? {
    let watcher = FileSystemDirectoryWatcher(directory: directory)
    do {
      try watcher.start(onChange: onChange)
      return watcher
    } catch {
      return nil  // 目录还不存在（例如开发目录被移走）：轮询仍会发现它回来
    }
  }

  /// 每隔 `pollInterval` 在后台算一遍开发目录指纹，和上一轮比较。第一轮只记基线。
  private func startPolling() {
    let interval = pollInterval
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        guard let folders = self?.developmentFolders else { return }
        let current = await Self.fingerprints(of: folders)
        self?.apply(fingerprints: current)
      }
    }
  }

  /// 和上一轮指纹比较，变化的开发目录记为待通知。目录消失（nil）也算变化。
  private func apply(fingerprints current: [String: Int?]) {
    for (folder, value) in current where developmentFolders.contains(folder) {
      if let previous = fingerprints[folder], previous != value { noteChange(folder: folder) }
      fingerprints[folder] = value
    }
  }

  /// 记一次变化并去抖：短时间内的多次事件合成一次回调。
  private func noteChange(folder: String?) {
    if let folder { pendingFolders.insert(folder) }
    hasPendingChange = true
    debounceTask?.cancel()
    let delay = debounce
    debounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      self?.deliverPendingChange()
    }
  }

  /// 把合并后的变化交给回调。
  private func deliverPendingChange() {
    guard hasPendingChange else { return }
    let folders = pendingFolders
    pendingFolders = []
    hasPendingChange = false
    debounceTask = nil
    onChange?(folders)
  }

  /// 后台计算每个开发目录的指纹。
  @concurrent
  private nonisolated static func fingerprints(of folders: [String]) async -> [String: Int?] {
    var result: [String: Int?] = [:]
    for folder in folders { result[folder] = ToolPluginScanner.fingerprint(of: folder) }
    return result
  }
}
