// bar 的 `branch` 触发源：监听当前目录所在仓库的 git 目录，HEAD 真的变了（切分支、detach）才通知。
// 每个窗口一份，按仓库去重：在同一仓库里 `cd` 不重建监听。查找仓库与读 HEAD 都在后台、有界。
import AsterCore
import Darwin
import Foundation

/// 当前目录的 git 分支监听。只在主线程使用。
@MainActor
final class ToolBranchWatcher {
  /// 向上找 `.git` 的最多层数，与 `TabTitleRuleService.currentBranch` 相同。
  nonisolated static let maximumDepth = 8
  /// `.git` 文件（worktree / submodule）与 HEAD 最多读的字节数。
  nonisolated static let maximumFileBytes = 4_096

  /// 一个仓库：工作树根、git 目录（worktree 时是 `.git` 文件指向的目录）与 HEAD 文件。
  struct Repository: Equatable, Sendable {
    let root: String
    let gitDirectory: String
    let headFile: String
  }

  /// 当前目录的分支变了（含进出仓库）。
  var onBranchChange: (() -> Void)?
  /// 当前目录所在仓库的分支；不在仓库里、远端或还没查到时为 nil。detached HEAD 是短 SHA。
  private(set) var branch: String?
  private(set) var directory: String?
  /// `branch` 是对哪个目录读出来的；换目录后、后台结果回来前与 `directory` 不同。
  private var resolvedDirectory: String?
  private(set) var repository: Repository?
  private var watcher: FileSystemDirectoryWatcher?
  private var task: Task<Void, Never>?
  /// 每次换目录或读 HEAD 加一；迟到的旧结果丢弃。
  private var generation = 0

  init() {}

  /// 换监听目录；nil 表示没有本地目录（远端或非终端 Pane）。同一目录重复调用不做事。
  func watch(directory newDirectory: String?) {
    guard newDirectory != directory else { return }
    directory = newDirectory
    guard let newDirectory else {
      generation += 1
      task?.cancel()
      resolvedDirectory = nil
      setRepository(nil)
      setBranch(nil)
      return
    }
    reload(for: newDirectory) { await Self.locate(from: newDirectory) }
  }

  /// `directory` 的分支。后台结果回来前：新目录仍在当前仓库里就沿用已知分支（仓库内 `cd` 不让分支先变 nil
  /// 再变回来），否则为 nil。
  func branch(for directory: String?) -> String? {
    guard let directory else { return nil }
    if directory == resolvedDirectory { return branch }
    guard let repository, directory == repository.root || directory.hasPrefix(repository.root + "/") else {
      return nil
    }
    return branch
  }

  /// 停止监听（窗口关闭）。
  func stop() {
    generation += 1
    task?.cancel()
    task = nil
    watcher?.stop()
    watcher = nil
    repository = nil
    directory = nil
    resolvedDirectory = nil
  }

  // MARK: - 后台读取

  /// 在后台读一次，结果按代次回到主线程：仓库变了换监听，分支变了通知。
  private func reload(for directory: String, _ read: @escaping @Sendable () async -> (Repository, String?)?) {
    generation += 1
    let generation = generation
    task?.cancel()
    task = Task { [weak self] in
      let found = await read()
      guard let self, self.generation == generation, !Task.isCancelled else { return }
      // 换到另一个仓库、分支名恰好相同时 `branch` 不变，但 `branch(for:)` 的答案从 nil 变成了有值，也要通知。
      let changed = self.resolvedDirectory != directory || self.branch != found?.1
      self.resolvedDirectory = directory
      self.branch = found?.1
      self.setRepository(found?.0)
      if changed { self.onBranchChange?() }
    }
  }

  /// 仓库变了才重建监听：只看 git 目录里的 HEAD，`index` 等频繁写入不会唤醒比较。
  private func setRepository(_ newRepository: Repository?) {
    guard newRepository != repository else { return }
    watcher?.stop()
    watcher = nil
    repository = newRepository
    guard let newRepository else { return }
    let watcher = FileSystemDirectoryWatcher(directory: URL(fileURLWithPath: newRepository.gitDirectory))
    do {
      try watcher.start(onChangeOf: URL(fileURLWithPath: newRepository.headFile)) { [weak self] in
        self?.headDidChange()
      }
      self.watcher = watcher
    } catch {
      // git 目录打不开（权限、刚被删）时不监听；分支仍按每次换目录时读到的值。
      self.watcher = nil
    }
  }

  /// HEAD 变了：后台重读。
  private func headDidChange() {
    guard let repository, let directory else { return }
    let headFile = repository.headFile
    reload(for: directory) { await Self.readBranch(repository: repository, headFile: headFile) }
  }

  /// 分支变了才通知。
  private func setBranch(_ newBranch: String?) {
    guard newBranch != branch else { return }
    branch = newBranch
    onBranchChange?()
  }

  /// 从 `directory` 向上找仓库并读分支。
  @concurrent
  nonisolated static func locate(from directory: String) async -> (Repository, String?)? {
    guard let repository = findRepository(from: directory) else { return nil }
    return (repository, branch(fromHeadFile: repository.headFile))
  }

  /// 重读 HEAD。
  @concurrent
  private nonisolated static func readBranch(repository: Repository, headFile: String) async -> (Repository, String?)? {
    (repository, branch(fromHeadFile: headFile))
  }

  /// 向上最多 `maximumDepth` 层找 `.git`：目录直接用；文件（worktree、submodule）按 `gitdir:` 指向的目录。
  nonisolated static func findRepository(from directory: String) -> Repository? {
    var url = URL(fileURLWithPath: directory).standardizedFileURL
    for _ in 0..<maximumDepth {
      let dotGit = url.appendingPathComponent(".git")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
        let gitDirectory: URL?
        if isDirectory.boolValue {
          gitDirectory = dotGit
        } else {
          gitDirectory = readPrefix(dotGit.path).flatMap { gitDirectoryPointer($0, relativeTo: url) }
        }
        guard let gitDirectory else { return nil }
        return Repository(
          root: url.path, gitDirectory: gitDirectory.path, headFile: gitDirectory.appendingPathComponent("HEAD").path)
      }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { break }
      url = parent
    }
    return nil
  }

  /// `.git` 文件内容 `gitdir: <path>`（相对路径相对工作树根）。
  nonisolated static func gitDirectoryPointer(_ text: String, relativeTo root: URL) -> URL? {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("gitdir:") else { return nil }
    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return nil }
    return path.hasPrefix("/")
      ? URL(fileURLWithPath: path).standardizedFileURL
      : root.appendingPathComponent(path).standardizedFileURL
  }

  /// 按 HEAD 内容取分支，规则与 `TabTitleRuleService.currentBranch` 相同：`ref: refs/heads/x` → x，否则短 SHA。
  nonisolated static func branch(fromHeadFile path: String) -> String? {
    guard let text = readPrefix(path) else { return nil }
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return nil }
    return line.hasPrefix("ref: refs/heads/") ? String(line.dropFirst("ref: refs/heads/".count)) : String(line.prefix(7))
  }

  /// 只读文件开头 `maximumFileBytes` 字节；读不到返回 nil（不在仓库或被删，按没有分支处理）。
  /// 用 POSIX 读取：只读描述符的 close 没有可处理的失败，不需要 FileHandle 的抛错 close。
  private nonisolated static func readPrefix(_ path: String) -> String? {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var buffer = [UInt8](repeating: 0, count: maximumFileBytes)
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count > 0 else { return nil }
    return String(decoding: buffer[0..<count], as: UTF8.self)
  }
}
