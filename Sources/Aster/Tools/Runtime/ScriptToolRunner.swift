// 脚本工具运行器：posix_spawn 启动插件程序（独立进程组、不经 shell），写完 stdin 即关闭，有界收集
// stdout / stderr；超时、取消与输出超限都先 SIGTERM 整个进程组，宽限期后 SIGKILL。协议细节见
// docs/developer/tools-and-plugins.md「脚本工具协议」。
import AsterCore
import Darwin
import Foundation
import os

/// 一次脚本运行的全部参数。可执行文件已解析成绝对路径；`environment` 是完整环境，不继承 Aster 进程。
struct ScriptToolInvocation: Equatable, Sendable {
  let executable: URL
  let arguments: [String]
  let workingDirectory: String
  let environment: [String: String]
  let stdin: Data
  /// 秒。
  let timeout: TimeInterval
  var stdoutLimit = ScriptToolProtocol.stdoutLimit
  var stderrLimit = ScriptToolProtocol.stderrLimit
  /// SIGTERM 之后等多久再 SIGKILL（秒）。
  var terminationGrace = ScriptToolProtocol.terminationGrace
}

/// 退出码为 0 时收集到的输出。
struct ScriptToolOutput: Equatable, Sendable {
  let stdout: Data
  let stderr: Data
}

/// 脚本运行入口。失败一律抛 `ScriptToolError`。
enum ScriptToolRunner {
  /// 运行到结束并返回输出。
  ///
  /// 阻塞的 poll 循环放在 GCD 线程上，不占 Swift 并发的协作线程池（脚本最长可跑 60 s）；
  /// 所在 Task 取消时进程组被结束，并抛 `.cancelled`。
  static func run(_ invocation: ScriptToolInvocation) async throws -> ScriptToolOutput {
    let flag = ScriptCancellationFlag()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            with: Result(catching: { try ScriptProcessExecution(invocation: invocation, flag: flag).run() }))
        }
      }
    } onCancel: {
      flag.cancel()
    }
  }

  /// 脚本固定拿到的基础环境。规则（只放行哪些键、固定 PATH、LANG 兜底、清理与截断）只在
  /// `ScriptToolProtocol.baseEnvironment(from:)` 定义一次；这里只给精简环境启动时可能缺的键补上系统值。
  static func baseEnvironment(
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let user = NSUserName()
    let systemFallbacks = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": user, "LOGNAME": user,
      "TMPDIR": NSTemporaryDirectory(), "SHELL": "/bin/zsh",
    ]
    let present = processEnvironment.filter { !$0.value.isEmpty }
    return ScriptToolProtocol.baseEnvironment(from: systemFallbacks.merging(present) { _, process in process })
  }

  /// 组装一次运行：解析可执行文件、工作目录、环境与 stdin，并建好插件数据目录。
  /// 会读写磁盘，只能在后台调用；失败抛 `ScriptToolError`。
  static func makeInvocation(
    action: ToolScriptAction,
    code: String,
    plugin: ToolPluginRuntimeInfo,
    input: ToolInput,
    query: String?,
    fileManager: FileManager = .default
  ) throws -> ScriptToolInvocation {
    let launch = try terminalLaunch(
      action: action, code: code, plugin: plugin, input: input, query: query, fileManager: fileManager)
    guard let executable = launch.command.first else { throw ScriptToolError.invalidCommand(L("命令为空")) }
    let stdin: Data
    do {
      stdin = try ScriptToolProtocol.stdinData(code: code, query: query, input: input, mode: action.stdin)
    } catch {
      throw ScriptToolError.launchFailed(error.localizedDescription)
    }
    return ScriptToolInvocation(
      executable: URL(fileURLWithPath: executable), arguments: Array(launch.command.dropFirst()),
      workingDirectory: launch.workingDirectory,
      environment: baseEnvironment().merging(launch.environment) { _, injected in injected },
      stdin: stdin, timeout: action.resolvedTimeout)
  }

  /// `output == terminal` 时交给新终端标签的命令、工作目录与 `ASTER_*` 变量（终端自带用户环境，不再给 PATH 等）。
  /// 同样会建插件数据目录，只能在后台调用。
  static func terminalLaunch(
    action: ToolScriptAction,
    code: String,
    plugin: ToolPluginRuntimeInfo,
    input: ToolInput,
    query: String?,
    fileManager: FileManager = .default
  ) throws -> (command: [String], workingDirectory: String, environment: [String: String]) {
    let (executable, arguments) = try ScriptToolProtocol.resolveExecutable(
      action.command, pluginDirectory: plugin.directory, fileManager: fileManager)
    try createDataDirectory(for: plugin, fileManager: fileManager)
    let environment = ScriptToolProtocol.environment(
      pluginID: plugin.manifest.id, code: code, query: query, input: input,
      pluginDirectory: plugin.directory.path, dataDirectory: plugin.dataDirectory.path)
    return ([executable.path] + arguments, workingDirectory(for: input, fileManager: fileManager), environment)
  }

  /// 组装一次 bar 视图脚本运行（界面扩展）。可执行文件解析与功能脚本相同；环境在功能脚本的 `ASTER_*`
  /// 之上（`ASTER_FEATURE = view:<id>`）追加 `ToolBarProtocol.environment`；stdout 上限按 bar 协议的 64 KiB，
  /// 超出整份作废。会读写磁盘，只能在后台调用；失败抛 `ScriptToolError`。
  static func makeViewInvocation(
    source: ToolViewScriptSource,
    viewID: String,
    trigger: ToolBarTrigger,
    context: ToolBarContext,
    plugin: ToolPluginRuntimeInfo,
    fileManager: FileManager = .default
  ) throws -> ScriptToolInvocation {
    let (executable, arguments) = try ScriptToolProtocol.resolveExecutable(
      source.command, pluginDirectory: plugin.directory, fileManager: fileManager)
    try createDataDirectory(for: plugin, fileManager: fileManager)
    // bar 上下文里的工作目录已按「远端为 nil」处理；借 ToolInput 复用功能脚本的 cwd 与环境规则。
    let input = ToolInput(
      context: ToolContext(
        workingDirectory: context.workingDirectory, isRemote: context.isRemote, locale: context.locale,
        appearance: context.appearance))
    let environment = ScriptToolProtocol.environment(
      pluginID: plugin.manifest.id, code: "view:\(viewID)", query: nil, input: input,
      pluginDirectory: plugin.directory.path, dataDirectory: plugin.dataDirectory.path
    ).merging(ToolBarProtocol.environment(viewID: viewID, trigger: trigger, context: context)) { _, bar in bar }
    return ScriptToolInvocation(
      executable: executable, arguments: arguments,
      workingDirectory: workingDirectory(for: input, fileManager: fileManager),
      environment: baseEnvironment().merging(environment) { _, injected in injected },
      stdin: ToolBarProtocol.stdinData(viewID: viewID, trigger: trigger, context: context),
      timeout: source.resolvedTimeout, stdoutLimit: ToolBarProtocol.stdoutLimit)
  }

  /// 建插件数据目录（`ASTER_PLUGIN_DATA`）；失败抛 `.launchFailed`。
  private static func createDataDirectory(for plugin: ToolPluginRuntimeInfo, fileManager: FileManager) throws {
    do {
      try fileManager.createDirectory(at: plugin.dataDirectory, withIntermediateDirectories: true)
    } catch {
      throw ScriptToolError.launchFailed(L("无法创建插件数据目录：\(error.localizedDescription)"))
    }
  }

  /// 工作目录：来源 Pane 的本地 cwd（仍存在时），否则用户主目录。远端 Pane 的路径在本机没有意义。
  static func workingDirectory(for input: ToolInput, fileManager: FileManager = .default) -> String {
    var isDirectory: ObjCBool = false
    if !input.context.isRemote, let path = input.context.workingDirectory,
      fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
    {
      return path
    }
    return fileManager.homeDirectoryForCurrentUser.path
  }
}

/// Task 取消回调与 poll 循环之间共享的取消标记。
final class ScriptCancellationFlag: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: false)

  /// 请求结束进程。
  func cancel() { state.withLock { $0 = true } }

  /// 是否已请求结束。
  var isCancelled: Bool { state.withLock { $0 } }
}

/// 一次运行的进程与管道。只在一个 GCD 线程上从头用到尾，不跨线程共享。
private final class ScriptProcessExecution {
  private let invocation: ScriptToolInvocation
  private let flag: ScriptCancellationFlag
  private let clock = ContinuousClock()
  /// 父进程持有的三端：写 stdin、读 stdout、读 stderr；-1 表示已关闭。
  private var stdinFD: Int32 = -1
  private var stdoutFD: Int32 = -1
  private var stderrFD: Int32 = -1
  /// 交给子进程的三端，spawn 后立即关闭。
  private var childFDs: [Int32] = []
  private var stdout = Data()
  private var stderr = Data()
  private var stdinOffset = 0
  private var pid: pid_t = 0
  private var reaped = false

  init(invocation: ScriptToolInvocation, flag: ScriptCancellationFlag) {
    self.invocation = invocation
    self.flag = flag
  }

  /// 启动并等到结束。任何路径退出时都关闭全部描述符，并保证进程被结束、被回收。
  func run() throws -> ScriptToolOutput {
    defer {
      closeAll()
      if pid > 0, !reaped {
        kill(-pid, SIGKILL)
        reap()
      }
    }
    guard !flag.isCancelled else { throw ScriptToolError.cancelled }
    try launch()
    let deadline = clock.now.advanced(by: .seconds(invocation.timeout))
    var exitedAt: ContinuousClock.Instant?
    while true {
      if flag.isCancelled { try abort(.cancelled) }
      if exitedAt == nil, clock.now >= deadline { try abort(.timedOut) }
      if !pump(timeoutMilliseconds: 20) { try abort(.outputTooLarge) }
      if exitedAt == nil, leaderHasExited() { exitedAt = clock.now }
      guard let exitedAt else { continue }
      // 领头进程退出后再给管道一点时间读到 EOF；后台的后代进程可能一直握着管道。
      if (stdoutFD < 0 && stderrFD < 0) || clock.now - exitedAt >= .milliseconds(200) { break }
    }
    if stdoutFD >= 0 || stderrFD >= 0 {
      // 仍握着输出管道的后代进程属于这次运行，一并结束。领头进程还没回收，进程组 id 不会被别的进程复用。
      kill(-pid, SIGKILL)
      guard pump(timeoutMilliseconds: 0) else { throw ScriptToolError.outputTooLarge }
    }
    return try finish(status: reap())
  }

  // MARK: 启动

  /// 建三条管道并 posix_spawn：独立进程组、只继承 0/1/2、信号处置恢复默认、信号掩码清空。
  private func launch() throws {
    let argv = [invocation.executable.path] + invocation.arguments
    let environment = invocation.environment.map { "\($0.key)=\($0.value)" }.sorted()
    guard (argv + environment + [invocation.workingDirectory]).allSatisfy({ !$0.utf8.contains(0) }) else {
      throw ScriptToolError.invalidCommand(L("命令、环境或目录里不能有空字符"))
    }
    let stdinPipe = try makePipe(parentReads: false)
    let stdoutPipe = try makePipe(parentReads: true)
    let stderrPipe = try makePipe(parentReads: true)
    stdinFD = stdinPipe.write
    stdoutFD = stdoutPipe.read
    stderrFD = stderrPipe.read
    childFDs = [stdinPipe.read, stdoutPipe.write, stderrPipe.write]

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw launchError(errno) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw launchError(errno) }
    defer { posix_spawnattr_destroy(&attributes) }
    // Aster 自己忽略了一些信号（如 SIGPIPE）；子进程必须拿回默认处置，否则管道断开时不会退出。
    // SIGKILL / SIGSTOP 不能设置处置，从集合里去掉。
    var defaultSignals = ~sigset_t(0) & ~(Self.signalBit(SIGKILL) | Self.signalBit(SIGSTOP))
    var emptyMask = sigset_t(0)
    // CLOEXEC_DEFAULT：子进程只继承下面 dup2 的 0/1/2，Aster 打开的 PTY、socket 一个都不带过去。
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    let configured = [
      posix_spawnattr_setflags(&attributes, flags),
      posix_spawnattr_setpgroup(&attributes, 0),
      posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
      posix_spawnattr_setsigmask(&attributes, &emptyMask),
      posix_spawn_file_actions_adddup2(&actions, stdinPipe.read, STDIN_FILENO),
      posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO),
      posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO),
      posix_spawn_file_actions_addchdir_np(&actions, invocation.workingDirectory),
    ]
    if let failure = configured.first(where: { $0 != 0 }) { throw launchError(failure) }

    let argumentPointers = argv.map { strdup($0) } + [nil]
    let environmentPointers = environment.map { strdup($0) } + [nil]
    defer {
      argumentPointers.forEach { free($0) }
      environmentPointers.forEach { free($0) }
    }
    var child: pid_t = 0
    let result = posix_spawn(
      &child, invocation.executable.path, &actions, &attributes, argumentPointers, environmentPointers)
    guard result == 0 else { throw launchError(result) }
    pid = child
    // 关掉交给子进程的一端：子进程退出后读端才能收到 EOF，写 stdin 也才能在子进程不读时得到 EPIPE。
    childFDs.forEach { close($0) }
    childFDs = []
    if invocation.stdin.isEmpty { closeDescriptor(&stdinFD) }
  }

  /// 建一条管道。两端都 CLOEXEC，防止并发启动的其它子进程继承后把 EOF 拖住。
  /// 只有父进程那一端设非阻塞：O_NONBLOCK 属于打开的文件描述，dup2 给子进程的一端若也设上，
  /// 脚本读 stdin 会直接拿到 EAGAIN。父进程写 stdin 的一端关掉 SIGPIPE，子进程不读时只得到 EPIPE。
  /// 两端先登记进 `childFDs`，中途失败时由 `closeAll` 关闭；三条都建好后 `launch` 再把父进程一端分出去。
  private func makePipe(parentReads: Bool) throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else { throw launchError(errno) }
    childFDs.append(contentsOf: descriptors)
    for descriptor in descriptors where fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0 {
      throw launchError(errno)
    }
    let parent = parentReads ? descriptors[0] : descriptors[1]
    let flags = fcntl(parent, F_GETFL)
    guard flags >= 0, fcntl(parent, F_SETFL, flags | O_NONBLOCK) == 0 else { throw launchError(errno) }
    if !parentReads, fcntl(parent, F_SETNOSIGPIPE, 1) != 0 { throw launchError(errno) }
    return (descriptors[0], descriptors[1])
  }

  /// 把 errno 一类的错误码转成启动失败。
  private func launchError(_ code: Int32) -> ScriptToolError {
    .launchFailed(String(cString: strerror(code)))
  }

  /// 信号在 sigset_t 里的位。
  private static func signalBit(_ signal: Int32) -> sigset_t {
    sigset_t(1) << sigset_t(signal - 1)
  }

  // MARK: 读写循环

  /// poll 一轮后非阻塞地读 stdout / stderr、写 stdin。输出超限返回 false。
  private func pump(timeoutMilliseconds: Int32) -> Bool {
    var descriptors: [pollfd] = []
    if stdoutFD >= 0 { descriptors.append(pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0)) }
    if stderrFD >= 0 { descriptors.append(pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)) }
    if stdinFD >= 0 { descriptors.append(pollfd(fd: stdinFD, events: Int16(POLLOUT), revents: 0)) }
    if descriptors.isEmpty {
      if timeoutMilliseconds > 0 { usleep(UInt32(timeoutMilliseconds) * 1_000) }
      return true
    }
    // 返回值只用来等待；无论哪个描述符就绪，下面都做非阻塞读写，EAGAIN 直接跳过。
    _ = poll(&descriptors, nfds_t(descriptors.count), timeoutMilliseconds)
    guard drain(&stdoutFD, into: &stdout, limit: invocation.stdoutLimit),
      drain(&stderrFD, into: &stderr, limit: invocation.stderrLimit)
    else { return false }
    writeStdin()
    return true
  }

  /// 读完管道里现有的数据；读到 EOF 或出错时关闭该端。超过上限返回 false。
  private func drain(_ descriptor: inout Int32, into data: inout Data, limit: Int) -> Bool {
    guard descriptor >= 0 else { return true }
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        data.append(contentsOf: buffer[0..<count])
        if data.count > limit { return false }
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN {
        return true
      } else {
        closeDescriptor(&descriptor)
        return true
      }
    }
  }

  /// 尽量多写 stdin；写完或子进程不再读（EPIPE 等）时关闭写端，让脚本读到 EOF。
  private func writeStdin() {
    let data = invocation.stdin
    while stdinFD >= 0, stdinOffset < data.count {
      let chunk = min(data.count - stdinOffset, 65_536)
      let written = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return 0 }
        return write(stdinFD, base + stdinOffset, chunk)
      }
      if written > 0 {
        stdinOffset += written
      } else if written < 0, errno == EINTR {
        continue
      } else if written < 0, errno == EAGAIN {
        return
      } else {
        closeDescriptor(&stdinFD)
        return
      }
    }
    if stdinOffset >= data.count { closeDescriptor(&stdinFD) }
  }

  // MARK: 结束

  /// 领头进程是否已退出。用 WNOWAIT 只看不收：僵尸进程保留着 pid，进程组还能安全地发信号。
  private func leaderHasExited() -> Bool {
    var info = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    if result == 0 { return info.si_pid == pid }
    return errno == ECHILD
  }

  /// 结束整个进程组并抛出原因：先 SIGTERM，宽限期内领头进程退出就提前收尾，最后 SIGKILL 清掉剩下的。
  /// 等待期间继续读管道并丢弃，避免子进程卡在写满的管道上。
  private func abort(_ reason: ScriptToolError) throws -> Never {
    kill(-pid, SIGTERM)
    closeDescriptor(&stdinFD)
    let graceDeadline = clock.now.advanced(by: .seconds(invocation.terminationGrace))
    while clock.now < graceDeadline, !leaderHasExited() {
      stdout.removeAll(keepingCapacity: true)
      stderr.removeAll(keepingCapacity: true)
      _ = pump(timeoutMilliseconds: 20)
    }
    kill(-pid, SIGKILL)
    reap()
    throw reason
  }

  /// 回收领头进程，返回 wait 状态。
  @discardableResult
  private func reap() -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    reaped = true
    return status
  }

  /// 按退出状态给结果：0 返回输出；非 0 或被信号结束时带上 stderr 前 4 KiB。
  private func finish(status: Int32) throws -> ScriptToolOutput {
    let signal = status & 0x7f
    let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
    guard code == 0 else {
      let message = String(decoding: stderr.prefix(ScriptToolProtocol.stderrDisplayLimit), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw ScriptToolError.exitStatus(code, stderr: message)
    }
    return ScriptToolOutput(stdout: stdout, stderr: stderr)
  }

  /// 关闭一个描述符并置为 -1。
  private func closeDescriptor(_ descriptor: inout Int32) {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }

  /// 关闭全部仍打开的描述符。
  private func closeAll() {
    closeDescriptor(&stdinFD)
    closeDescriptor(&stdoutFD)
    closeDescriptor(&stderrFD)
    childFDs.forEach { close($0) }
    childFDs = []
  }
}
