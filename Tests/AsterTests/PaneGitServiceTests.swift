// 所有 Git 操作仅使用临时本地仓库和本地 bare remote，不访问网络。
import Foundation
import Testing

@testable import Aster

private var paneGitEnvironment: [String: String] {
  var values = ProcessInfo.processInfo.environment
  values["GIT_CONFIG_NOSYSTEM"] = "1"
  values["GIT_CONFIG_GLOBAL"] = "/dev/null"
  values["LC_ALL"] = "C"
  for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_TEMPLATE_DIR"] {
    values.removeValue(forKey: key)
  }
  return values
}

private func paneGitCommand(_ arguments: [String], at directory: URL) async throws -> String {
  try await Task.detached {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.environment = paneGitEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "PaneGitFixture", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output])
    }
    return output
  }.value
}

private func paneGitRepository() async throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aster Pane Git \(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  do {
    _ = try await paneGitCommand(["init", "--initial-branch=main", "--template="], at: url)
    _ = try await paneGitCommand(["config", "user.email", "pane-git@example.invalid"], at: url)
    _ = try await paneGitCommand(["config", "user.name", "Pane Git Test"], at: url)
    try Data("initial\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
    _ = try await paneGitCommand(["add", "tracked.txt"], at: url)
    _ = try await paneGitCommand(["commit", "-m", "initial"], at: url)
    return url
  } catch {
    try? FileManager.default.removeItem(at: url)
    throw error
  }
}

@Test("Pane Git 读取分支、暂存状态和已去除凭据的远程网页链接")
func paneGitServiceReadsRepositoryContext() async throws {
  let directory = try await paneGitRepository()
  defer { try? FileManager.default.removeItem(at: directory) }
  try Data("changed\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
  _ = try await paneGitCommand(["add", "tracked.txt"], at: directory)
  try Data().write(to: directory.appendingPathComponent("untracked.txt"))
  _ = try await paneGitCommand(["branch", "topic"], at: directory)
  _ = try await paneGitCommand(["remote", "add", "origin", "https://user:secret@example.invalid/team/repo.git"], at: directory)
  var environment = paneGitEnvironment
  environment["GIT_DIR"] = "/invalid-inherited-git-directory"
  environment["GIT_WORK_TREE"] = "/invalid-inherited-work-tree"
  let service = PaneGitService(environment: environment)
  let context = try await service.context(directory: directory.path)
  #expect(context.branch == "main")
  #expect(context.branches == ["main", "topic"])
  #expect(context.changedFiles == 2)
  #expect(context.stagedFiles == 1)
  #expect(context.remotes.first?.webURL?.absoluteString == "https://example.invalid/team/repo")
  #expect(try await service.prepareCommit(directory: directory.path).stagedSummary.contains("tracked.txt"))
}

@Test("Pane Git 创建切换合并和rebase真实执行，提交信息作为单独argv传递")
func paneGitServiceExecutesLocalBranchAndCommitActions() async throws {
  let directory = try await paneGitRepository()
  defer { try? FileManager.default.removeItem(at: directory) }
  let service = PaneGitService(environment: paneGitEnvironment)
  _ = try await service.perform(.createBranch("topic/feature"), directory: directory.path)
  try Data("topic\n".utf8).write(to: directory.appendingPathComponent("feature.txt"))
  _ = try await paneGitCommand(["add", "feature.txt"], at: directory)
  let message = "quoted \"value\" ; $(touch should-not-exist)"
  _ = try await service.perform(.commit(message), directory: directory.path)
  #expect(try await paneGitCommand(["log", "-1", "--format=%s"], at: directory).trimmingCharacters(in: .newlines) == message)
  #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
  _ = try await service.perform(.switchBranch("main"), directory: directory.path)
  _ = try await service.perform(.merge("topic/feature"), directory: directory.path)
  _ = try await service.perform(.rebase("topic/feature"), directory: directory.path)
  #expect(try await service.context(directory: directory.path).branch == "main")
  #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("feature.txt").path))
}

@Test("Pane Git Fetch和Pull只连接临时本地bare remote")
func paneGitServiceFetchesAndPullsLocalRemote() async throws {
  let directory = try await paneGitRepository()
  let remote = directory.deletingLastPathComponent().appendingPathComponent("Aster Pane Bare \(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: remote) }
  _ = try await paneGitCommand(["clone", "--bare", directory.path, remote.path], at: directory)
  _ = try await paneGitCommand(["remote", "add", "origin", remote.path], at: directory)
  let service = PaneGitService(environment: paneGitEnvironment)
  _ = try await service.perform(.fetch, directory: directory.path)
  _ = try await paneGitCommand(["branch", "--set-upstream-to=origin/main", "main"], at: directory)
  _ = try await service.perform(.pull, directory: directory.path)
  #expect(try await service.context(directory: directory.path).remotes.first?.webURL == nil)
}

@Test("Pane Git 拒绝远端路径和选项注入，并保留Git非零错误输出")
func paneGitServiceRejectsUnsafeTargetsAndReportsErrors() async throws {
  let directory = try await paneGitRepository()
  defer { try? FileManager.default.removeItem(at: directory) }
  let service = PaneGitService(environment: paneGitEnvironment)
  await #expect(throws: CocoaError.self) { try await service.context(directory: directory.path, isRemote: true) }
  await #expect(throws: PaneGitService.Failure.self) {
    try await service.perform(.merge("--abort"), directory: directory.path)
  }
  do {
    _ = try await service.perform(.merge("missing-branch"), directory: directory.path)
    Issue.record("缺失分支应失败")
  } catch PaneGitService.Failure.commandFailed(let code, let output) {
    #expect(code != 0)
    #expect(output.contains("missing-branch"))
  }
}

@Test("Pane Git 超时和取消终止后台Git及其hook进程组", arguments: [false, true])
func paneGitServiceStopsTimedOutAndCancelledOperations(cancel: Bool) async throws {
  let directory = try await paneGitRepository()
  defer { try? FileManager.default.removeItem(at: directory) }
  let hooks = directory.appendingPathComponent(".git/hooks")
  try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
  let hook = hooks.appendingPathComponent("pre-commit")
  // 固定的测试hook只在临时仓库运行，用于让Git派生可取消的子进程。
  try Data("#!/bin/sh\nprintf 'hook started\\n' >&2\nprintf '%s' \"$$\" > .git/hook-started\nsleep 20\n".utf8).write(to: hook)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
  try Data("new\n".utf8).write(to: directory.appendingPathComponent("tracked.txt"))
  _ = try await paneGitCommand(["add", "tracked.txt"], at: directory)
  var service = PaneGitService(environment: paneGitEnvironment)
  service.operationTimeout = cancel ? 10 : 2
  let configured = service
  let started = ContinuousClock.now
  let task = Task { try await configured.perform(.commit("must not complete"), directory: directory.path) }
  if cancel {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/hook-started").path),
      ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
  }
  do {
    _ = try await task.value
    Issue.record("等待中的Git必须取消或超时")
  } catch is CancellationError {
    #expect(cancel)
  } catch PaneGitService.Failure.timedOut(let output) {
    #expect(!cancel)
    #expect(output.contains("hook started"))
  }
  #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/hook-started").path))
  #expect(started.duration(to: .now) < .seconds(5))
  #expect(try await paneGitCommand(["log", "-1", "--format=%s"], at: directory).trimmingCharacters(in: .newlines) == "initial")
}
