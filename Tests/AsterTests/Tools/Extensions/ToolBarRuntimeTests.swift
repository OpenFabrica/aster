// bar 运行时的周边：视图脚本调用的组装（ASTER_FEATURE = view:<id>、cwd、超时与 64 KiB 输出上限），
// 分支监听的仓库查找（.git 目录与 worktree 的 .git 文件）与 HEAD 解析。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Suite("界面扩展：bar 运行时")
struct ToolBarRuntimeTests {
  /// 临时目录（已解析符号链接）。
  private func makeTemporaryDirectory(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("视图脚本调用：功能码是 view:<id>，cwd 取本地目录，远端退回主目录，超时与输出上限按 bar 协议")
  func viewInvocationUsesViewCodeAndBarLimits() async throws {
    let root = try makeTemporaryDirectory("bar-plugin")
    defer { try? FileManager.default.removeItem(at: root) }
    let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
    let script = pluginDirectory.appendingPathComponent("bin/bar.sh")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\ncat >/dev/null\nprintf '{\"items\":[{\"text\":\"%s %s\"}],\"ttl\":60}' \"$ASTER_VIEW\" \"$ASTER_TRIGGER\"\n".utf8)
      .write(to: script)
    try makeExecutable(script)
    let manifest = ToolManifest(
      id: "com.example.bar", name: "Bar", version: "1.0.0", permissions: [.exec],
      features: [ToolFeature(code: "run", title: "Run", action: .ui)])
    let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
    let plugin = ToolPluginRuntimeInfo(
      manifest: manifest, source: .user, directory: pluginDirectory, dataDirectory: dataDirectory,
      grantedPermissions: [.exec], grantedNetworkDomains: [])
    let source = ToolViewScriptSource(command: ["bin/bar.sh", "--flag"], timeout: 7)

    let local = try ScriptToolRunner.makeViewInvocation(
      source: source, viewID: "branch", trigger: .cwd,
      context: ToolBarContext(workingDirectory: root.path, branch: "main"), plugin: plugin)
    #expect(local.executable.path == canonicalToolPath(script))
    #expect(local.arguments == ["--flag"])
    #expect(local.workingDirectory == root.path)
    #expect(local.environment["ASTER_FEATURE"] == "view:branch")
    #expect(local.environment["ASTER_CWD"] == root.path)
    #expect(local.environment["ASTER_PLUGIN_ID"] == "com.example.bar")
    #expect(local.environment["PATH"] == ScriptToolProtocol.defaultPath)
    #expect(local.timeout == 7)
    #expect(local.stdoutLimit == ToolBarProtocol.stdoutLimit)
    #expect(FileManager.default.fileExists(atPath: dataDirectory.path))
    // 真跑一次：stdin 写完即关、环境里有视图与触发，stdout 按 bar 协议解析。
    let output = try await ScriptToolRunner.run(local)
    let parsed = try ToolBarProtocol.parse(output.stdout, pluginDirectory: pluginDirectory)
    #expect(parsed.items.map(\.text) == ["branch cwd"])
    #expect(parsed.ttl == 60)

    let remote = try ScriptToolRunner.makeViewInvocation(
      source: source, viewID: "branch", trigger: .interval, context: ToolBarContext(isRemote: true), plugin: plugin)
    #expect(remote.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    #expect(remote.environment["ASTER_CWD"] == nil)
  }

  @Test("分支监听找仓库：向上找 .git 目录；worktree 的 .git 文件按 gitdir 指向；HEAD 解析分支或短 SHA")
  func branchWatcherFindsRepositoryAndParsesHead() throws {
    let root = try makeTemporaryDirectory("branch")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    let gitDirectory = repo.appendingPathComponent(".git", isDirectory: true)
    let nested = repo.appendingPathComponent("a/b", isDirectory: true)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("ref: refs/heads/feature/x\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))

    let found = try #require(ToolBranchWatcher.findRepository(from: nested.path))
    #expect(found.root == repo.standardizedFileURL.path)
    #expect(found.gitDirectory == gitDirectory.standardizedFileURL.path)
    #expect(ToolBranchWatcher.branch(fromHeadFile: found.headFile) == "feature/x")

    // worktree：.git 是文件，指向别处的 git 目录；detached HEAD 取前 7 位。
    let worktree = root.appendingPathComponent("worktree", isDirectory: true)
    let worktreeGit = root.appendingPathComponent("repo/.git/worktrees/wt", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
    try Data("gitdir: ../repo/.git/worktrees/wt\n".utf8).write(to: worktree.appendingPathComponent(".git"))
    try Data("0123456789abcdef\n".utf8).write(to: worktreeGit.appendingPathComponent("HEAD"))
    let linked = try #require(ToolBranchWatcher.findRepository(from: worktree.path))
    #expect(linked.gitDirectory == worktreeGit.standardizedFileURL.path)
    #expect(ToolBranchWatcher.branch(fromHeadFile: linked.headFile) == "0123456")

    #expect(ToolBranchWatcher.findRepository(from: root.path) == nil)
  }

  @Test("分支监听：切分支（HEAD 改写）后通知；在仓库里 cd 不先变 nil")
  @MainActor
  func branchWatcherNotifiesOnHeadChange() async throws {
    let root = try makeTemporaryDirectory("branch-watch")
    defer { try? FileManager.default.removeItem(at: root) }
    let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
    let nested = root.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let head = gitDirectory.appendingPathComponent("HEAD")
    try Data("ref: refs/heads/main\n".utf8).write(to: head)

    let watcher = ToolBranchWatcher()
    defer { watcher.stop() }
    var notifications = 0
    watcher.onBranchChange = { notifications += 1 }
    watcher.watch(directory: root.path)
    await pollUntil { watcher.branch(for: root.path) == "main" }
    #expect(watcher.branch(for: root.path) == "main")
    watcher.watch(directory: nested.path)
    #expect(watcher.branch(for: nested.path) == "main")

    let before = notifications
    try Data("ref: refs/heads/dev\n".utf8).write(to: head, options: .atomic)
    await pollUntil { watcher.branch(for: nested.path) == "dev" }
    #expect(watcher.branch(for: nested.path) == "dev")
    #expect(notifications > before)
  }
}
