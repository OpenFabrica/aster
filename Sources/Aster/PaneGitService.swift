// Pane Git 的只读快照与真实操作；固定 argv、后台进程组、有界输出与取消。
import Darwin
import AsterCore
import Foundation

struct PaneGitService: Sendable {
  struct Output: Equatable, Sendable {
    var stdout: String = ""
    var stderr: String = ""
    var text: String { [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n") }
  }

  struct Remote: Equatable, Sendable {
    let name: String
    let address: String
    let webURL: URL?
  }

  struct Context: Equatable, Sendable {
    let directory: String
    let branch: String
    let branches: [String]
    let changedFiles: Int
    let stagedFiles: Int
    let remotes: [Remote]
  }

  struct CommitPreparation: Equatable, Sendable {
    let context: Context
    let stagedSummary: String
  }

  enum Operation: Equatable, Sendable {
    case fetch, pull, push
    case createBranch(String), switchBranch(String), merge(String), rebase(String)
    case commit(String)

    var arguments: [String] {
      switch self {
      case .fetch: ["fetch"]
      case .pull: ["pull"]
      case .push: ["push"]
      case .createBranch(let name): ["checkout", "-b", name]
      case .switchBranch(let name): ["checkout", name, "--"]
      case .merge(let name): ["merge", name]
      case .rebase(let name): ["rebase", name]
      case .commit(let message): ["commit", "-m", message]
      }
    }
  }

  enum Failure: Error, LocalizedError, Sendable {
    case invalidArgument
    case timedOut(String)
    case outputLimit
    case commandFailed(Int32, String)
    case noStagedChanges

    var errorDescription: String? {
      switch self {
      case .invalidArgument: L("Git 参数无效。")
      case .timedOut(let output): [L("Git 操作超时。"), output].filter { !$0.isEmpty }.joined(separator: "\n")
      case .outputLimit: L("Git 输出超出大小限制。")
      case .noStagedChanges: L("没有已暂存的改动。")
      case .commandFailed(let status, let output):
        [L("Git 操作失败（退出码 \(String(status))）。"), output].filter { !$0.isEmpty }.joined(separator: "\n")
      }
    }
  }

  typealias Runner = @Sendable (_ directory: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> Output
  var operationTimeout: TimeInterval = 90
  var queryTimeout: TimeInterval = 10
  private let runner: Runner

  init(
    executable: String = "/usr/bin/git",
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runner: Runner? = nil
  ) {
    self.runner = runner ?? { directory, arguments, timeout in
      var environment = environment
      for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES"] { environment.removeValue(forKey: key) }
      // 菜单操作没有交互式 stdin；认证失败必须返回，不能在后台等待密码输入。
      environment["GIT_TERMINAL_PROMPT"] = "0"
      let process = PaneGitProcess(executable: executable, environment: environment)
      let task = Task.detached(priority: .userInitiated) {
        try process.run(directory: directory, arguments: arguments, timeout: timeout)
      }
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: { task.cancel() }
    }
  }

  /// 所有 Git 查询均异步执行。远端 Pane 必须由调用方标记，不能把远端绝对路径当作本机路径。
  func context(directory: String?, isRemote: Bool = false) async throws -> Context {
    let directory = try localDirectory(directory, isRemote: isRemote)
    _ = try await runner(directory, ["rev-parse", "--show-toplevel"], queryTimeout)
    async let branch = runner(directory, ["branch", "--show-current"], queryTimeout)
    async let branches = runner(directory, ["for-each-ref", "--format=%(refname:short)", "refs/heads"], queryTimeout)
    async let status = runner(directory, ["status", "--porcelain=v1", "-z"], queryTimeout)
    async let remotes = runner(directory, ["remote", "-v"], queryTimeout)
    let values = try await (branch, branches, status, remotes)
    let counts = Self.statusCounts(values.2.stdout)
    return Context(directory: directory, branch: values.0.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
      branches: values.1.stdout.split(whereSeparator: \.isNewline).map(String.init),
      changedFiles: counts.changed, stagedFiles: counts.staged, remotes: Self.parseRemotes(values.3.stdout))
  }

  func prepareCommit(directory: String?, isRemote: Bool = false) async throws -> CommitPreparation {
    let context = try await context(directory: directory, isRemote: isRemote)
    let summary = try await runner(context.directory, ["diff", "--cached", "--stat"], queryTimeout)
    return CommitPreparation(context: context, stagedSummary: summary.stdout)
  }

  /// 执行单个用户已确认的操作。Push/Pull 确认由菜单负责；本层不隐式 stage、重试或回滚。
  /// 失败保留 Git 输出，merge/rebase 冲突保持在仓库中供用户处理。
  func perform(_ operation: Operation, directory: String?, isRemote: Bool = false) async throws -> Output {
    let directory = try localDirectory(directory, isRemote: isRemote)
    try Task.checkCancellation()
    switch operation {
    case .createBranch(let name), .switchBranch(let name), .merge(let name), .rebase(let name):
      guard !name.isEmpty, !name.hasPrefix("-"),
        !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      else { throw Failure.invalidArgument }
      _ = try await runner(directory, ["check-ref-format", "--branch", name], queryTimeout)
    case .commit(let message):
      guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0") else {
        throw Failure.invalidArgument
      }
    default: break
    }
    return try await runner(directory, operation.arguments, operationTimeout)
  }

  private func localDirectory(_ path: String?, isRemote: Bool) throws -> String {
    guard !isRemote else { throw CocoaError(.fileReadUnsupportedScheme) }
    guard let path, path.hasPrefix("/"), !path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
    // 磁盘检查由后台 git -C 执行，保持主线程调用无文件系统等待。
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
  }

  private static func statusCounts(_ text: String) -> (changed: Int, staged: Int) {
    let entries = text.split(separator: "\0", omittingEmptySubsequences: true)
    var index = 0
    var changed = 0
    var staged = 0
    while index < entries.count {
      let codes = Array(entries[index].prefix(2))
      guard codes.count == 2 else { index += 1; continue }
      changed += 1
      if codes[0] != " " && codes[0] != "?" { staged += 1 }
      index += codes.contains("R") || codes.contains("C") ? 2 : 1
    }
    return (changed, staged)
  }

  private static func parseRemotes(_ output: String) -> [Remote] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      guard line.hasSuffix(" (fetch)"), let tab = line.firstIndex(of: "\t") else { return nil }
      let name = String(line[..<tab])
      let address = String(line[line.index(after: tab)...].dropLast(8))
      return Remote(name: name, address: address, webURL: webURL(address))
    }
  }

  private static func webURL(_ address: String) -> URL? {
    var components: URLComponents?
    if address.contains("://") {
      components = URLComponents(string: address)
      guard ["https", "http", "ssh", "git"].contains(components?.scheme ?? "") else { return nil }
      if components?.scheme == "ssh" || components?.scheme == "git" { components?.scheme = "https"; components?.port = nil }
    } else if let colon = address.firstIndex(of: ":"), !address[..<colon].contains("/") {
      let host = address[..<colon].split(separator: "@").last.map(String.init) ?? ""
      components = URLComponents(string: "https://" + host + "/" + String(address[address.index(after: colon)...]))
    }
    guard var components, let host = components.host, !host.isEmpty else { return nil }
    components.user = nil
    components.password = nil
    if components.path.hasSuffix(".git") { components.path.removeLast(4) }
    return components.url
  }
}

/// 同步实现只由 detached task 调用。stdout/stderr 分别有界读取，终止整个独立进程组。
private struct PaneGitProcess: Sendable {
  let executable: String
  let environment: [String: String]
  let maximumOutputBytes = 1_048_576

  func run(directory: String, arguments: [String], timeout: TimeInterval) throws -> PaneGitService.Output {
    try Task.checkCancellation()
    guard timeout.isFinite, timeout > 0, !executable.contains("\0"),
      arguments.allSatisfy({ !$0.contains("\0") }) else { throw PaneGitService.Failure.invalidArgument }
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw posixFailure() }
    defer { close(descriptors[0]); if descriptors[1] >= 0 { close(descriptors[1]) } }
    guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { throw posixFailure() }
    var errors: [Int32] = [0, 0]
    guard pipe(&errors) == 0 else { throw posixFailure() }
    defer { close(errors[0]); if errors[1] >= 0 { close(errors[1]) } }
    guard fcntl(errors[0], F_SETFL, O_NONBLOCK) == 0 else { throw posixFailure() }
    for descriptor in descriptors + errors {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw posixFailure() }
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw posixFailure() }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { throw posixFailure() }
    defer { posix_spawnattr_destroy(&attributes) }
    for result in [
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
      posix_spawnattr_setpgroup(&attributes, 0),
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
      posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
      posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO),
      posix_spawn_file_actions_addclose(&actions, descriptors[0]),
      posix_spawn_file_actions_addclose(&actions, descriptors[1]),
      posix_spawn_file_actions_addclose(&actions, errors[0]),
      posix_spawn_file_actions_addclose(&actions, errors[1]),
    ] where result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    var argv = ([executable, "-C", directory] + arguments).map { strdup($0) } + [nil]
    var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
    var pid: pid_t = 0
    let result = argv.withUnsafeMutableBufferPointer { argv in
      env.withUnsafeMutableBufferPointer { env in
        posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    close(descriptors[1])
    descriptors[1] = -1
    close(errors[1])
    errors[1] = -1
    var reaped = false
    var finished = false
    defer {
      if !finished {
        // 先给Git清理自身锁文件的机会，再收掉忽略SIGTERM的hook或认证子进程。
        kill(-pid, SIGTERM)
        let cleanupDeadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        while ContinuousClock.now < cleanupDeadline && kill(-pid, 0) == 0 {
          if !reaped, waitpid(pid, nil, WNOHANG) == pid { reaped = true }
          usleep(5_000)
        }
        kill(-pid, SIGKILL)
      }
      if !reaped { while waitpid(pid, nil, 0) < 0 && errno == EINTR {} }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    var output = Data()
    var errorOutput = Data()
    var status: Int32 = 0
    var buffer = [UInt8](repeating: 0, count: 8_192)
    var eof = false
    var errorEOF = false
    while true {
      try Task.checkCancellation()
      let count = read(descriptors[0], &buffer, buffer.count)
      if count > 0 {
        guard output.count + errorOutput.count + count <= maximumOutputBytes else { throw PaneGitService.Failure.outputLimit }
        output.append(contentsOf: buffer.prefix(count))
      } else if count == 0 { eof = true }
      else if errno != EAGAIN && errno != EINTR { throw posixFailure() }
      let errorCount = read(errors[0], &buffer, buffer.count)
      if errorCount > 0 {
        guard output.count + errorOutput.count + errorCount <= maximumOutputBytes else { throw PaneGitService.Failure.outputLimit }
        errorOutput.append(contentsOf: buffer.prefix(errorCount))
      } else if errorCount == 0 { errorEOF = true }
      else if errno != EAGAIN && errno != EINTR { throw posixFailure() }
      // 先保留管道中已产生的诊断，再报告超时，避免调度延迟丢掉最后一条错误。
      if clock.now >= deadline {
        throw PaneGitService.Failure.timedOut(String(decoding: output + errorOutput, as: UTF8.self))
      }
      if !reaped {
        let state = waitpid(pid, &status, WNOHANG)
        if state == pid { reaped = true }
        else if state < 0 && errno != EINTR { throw posixFailure() }
      }
      if reaped && eof && errorEOF {
        finished = true
        let result = PaneGitService.Output(stdout: String(decoding: output, as: UTF8.self),
          stderr: String(decoding: errorOutput, as: UTF8.self))
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
          let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
          throw PaneGitService.Failure.commandFailed(code, result.text)
        }
        return result
      }
      if count <= 0 && errorCount <= 0 { usleep(5_000) }
    }
  }

  private func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
