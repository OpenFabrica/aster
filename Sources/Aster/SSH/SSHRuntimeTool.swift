import Foundation
import os

// 运行 aster-ssh 的一次性 JSON 子命令（`keys …`、`known-hosts …`）。
// 请求经 stdin 传入，结果从 stdout 读回：私钥、口令等秘密从不进 argv（`ps` 可见），
// stdout/stderr 内容也从不写入日志或诊断，失败只带退出码与固定摘要。

/// aster-ssh JSON 子命令的失败。
enum SSHRuntimeToolError: Error, Equatable {
  /// 找不到 aster-ssh 可执行文件。
  case executableMissing
  /// 进程无法启动；只含系统错误描述，不含输出。
  case launchFailed(String)
  /// 超时未退出，进程已被终止。
  case timedOut
  /// stdout 超过上限，进程已被终止。
  case outputTooLarge
  /// 非零退出；`stdout` 是子命令约定的错误 JSON（可能为空）。
  case exited(code: Int32, stdout: Data)
}

/// aster-ssh JSON 子命令运行器。无状态，可在任意线程使用。
struct SSHRuntimeTool: Sendable {
  /// aster-ssh 可执行文件。
  let executableURL: URL
  /// 单次调用超时秒数。
  var timeout: TimeInterval = 15
  /// stdout 读取上限（字节）。
  var maximumOutputBytes: Int = 4 * 1024 * 1024

  /// 用 broker 同一套规则定位 aster-ssh；找不到返回 nil。
  static func located() -> SSHRuntimeTool? {
    SSHBrokerSupervisor.executableURL().map { SSHRuntimeTool(executableURL: $0) }
  }

  /// 运行 `aster-ssh <arguments…>`，把 `input` 写进 stdin 后关闭，返回退出码为 0 时的 stdout。
  /// 非零退出抛 `.exited`，调用方按子命令约定解析其中的错误 JSON。
  func run(_ arguments: [String], input: Data) async throws -> Data {
    let executableURL = executableURL
    let timeout = timeout
    let maximumOutputBytes = maximumOutputBytes
    return try await Task.detached(priority: .userInitiated) {
      try Self.runBlocking(
        executableURL: executableURL, arguments: arguments, input: input,
        timeout: timeout, maximumOutputBytes: maximumOutputBytes)
    }.value
  }

  /// 同步执行；只在后台任务里调用，不能占用主线程。
  private static func runBlocking(
    executableURL: URL, arguments: [String], input: Data,
    timeout: TimeInterval, maximumOutputBytes: Int
  ) throws -> Data {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    // stderr 可能含诊断细节，直接丢弃，避免任何内容进入 App 日志。
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw SSHRuntimeToolError.launchFailed(error.localizedDescription)
    }

    // 先在独立线程写 stdin 再关闭，避免请求较大时与 stdout 读取互相阻塞。
    let writer = Thread {
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
    }
    writer.start()

    // 超时由看门狗终止进程；终止后 stdout 关闭，下面的读循环随之结束。
    let timedOut = OSAllocatedUnfairLock(initialState: false)
    let watchdog = DispatchWorkItem {
      timedOut.withLock { $0 = true }
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    defer { watchdog.cancel() }

    let reader = stdout.fileHandleForReading
    var output = Data()
    var overflow = false
    while true {
      let chunk = reader.availableData
      if chunk.isEmpty { break }
      output.append(chunk)
      if output.count > maximumOutputBytes {
        overflow = true
        process.terminate()
        break
      }
    }
    process.waitUntilExit()
    if timedOut.withLock({ $0 }) { throw SSHRuntimeToolError.timedOut }
    if overflow { throw SSHRuntimeToolError.outputTooLarge }
    guard process.terminationStatus == 0 else {
      throw SSHRuntimeToolError.exited(code: process.terminationStatus, stdout: output)
    }
    return output
  }
}

