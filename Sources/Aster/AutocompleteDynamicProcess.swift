// 动态候选的固定 argv 执行器：隔离进程组、总期限和有界输出，不经过 Shell。
import Darwin
import Foundation

struct AutocompleteDynamicProcess: Sendable {
  let environment: [String: String]
  var maximumOutputBytes = 1_048_576

  /// 在非主线程调用。退出非零、超时、取消、启动或读取失败均返回 nil；不保留部分输出。
  /// 命令来自原生固定表，调用方不得传入 Fig 或项目文件中的任意 script。
  func run(arguments: [String], directory: String, timeout: TimeInterval) -> String? {
    guard !arguments.isEmpty, timeout.isFinite, timeout > 0, !Task.isCancelled,
      !directory.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }),
      let executable = resolve(arguments[0], directory: directory) else { return nil }
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { return nil }
    defer { close(descriptors[0]); close(descriptors[1]) }
    guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { return nil }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
      posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
      posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
      posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
      directory.isEmpty || posix_spawn_file_actions_addchdir_np(&actions, directory) == 0
    else { return nil }

    let argv = [executable] + arguments.dropFirst()
    var argumentPointers = argv.map { strdup($0) } + [nil]
    var environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argumentPointers.forEach { free($0) }
      environmentPointers.forEach { free($0) }
    }
    var pid: pid_t = 0
    let launched = argumentPointers.withUnsafeMutableBufferPointer { argv in
      environmentPointers.withUnsafeMutableBufferPointer { env in
        posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, env.baseAddress!)
      }
    }
    guard launched == 0 else { return nil }
    // 关闭父进程的写端，子进程结束后读端才能收到 EOF。
    close(descriptors[1])
    descriptors[1] = -1
    var reaped = false
    var succeeded = false
    defer {
      if !succeeded { kill(-pid, SIGKILL) }
      if !reaped {
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
      }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    var output = Data()
    var status: Int32 = 0
    var buffer = [UInt8](repeating: 0, count: 8_192)
    var eof = false
    while !Task.isCancelled && clock.now < deadline {
      let size = read(descriptors[0], &buffer, buffer.count)
      if size > 0 {
        guard output.count + size <= maximumOutputBytes else { return nil }
        output.append(contentsOf: buffer.prefix(size))
      } else if size == 0 { eof = true }
      else if errno != EAGAIN && errno != EINTR { return nil }
      if !reaped {
        let finished = waitpid(pid, &status, WNOHANG)
        if finished == pid { reaped = true }
        else if finished < 0 && errno != EINTR { return nil }
      }
      if reaped && eof {
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else { return nil }
        succeeded = true
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if size <= 0 { usleep(5_000) }
    }
    // 即使根进程已退出，也结束仍持有输出管道的后代进程。
    kill(-pid, SIGKILL)
    return nil
  }

  private func resolve(_ name: String, directory: String) -> String? {
    let manager = FileManager.default
    let base = directory.isEmpty ? manager.currentDirectoryPath : directory
    func absolute(_ value: String) -> String {
      value.hasPrefix("/") ? value : URL(fileURLWithPath: base).appendingPathComponent(value).path
    }
    let candidates = name.contains("/") ? [absolute(name)] : (environment["PATH"] ?? "/usr/bin:/bin")
      .split(separator: ":", omittingEmptySubsequences: false).map {
        absolute(($0.isEmpty ? "." : String($0)) + "/" + name)
      }
    return candidates.first { manager.isExecutableFile(atPath: $0) }
  }
}
