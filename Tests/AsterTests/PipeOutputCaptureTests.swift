// 真实管道与退出回调的竞争回归；不启动 App 或读取用户配置。
import Darwin
import Foundation
import Testing

@testable import Aster

@Test("孙进程保留 stdout 写端时，执行器仍立即返回已有输出")
func processRunnerDoesNotWaitForGrandchildToClosePipe() async {
  let started = ContinuousClock.now
  let output = await Task.detached {
    MemoryProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "echo ready; sleep 1 &"], timeout: 5)
  }.value
  #expect(output == "ready\n")
  #expect(ContinuousClock.now - started < .seconds(5))
}

@Test("空的非阻塞管道返回暂时无数据，之后到达的输出仍完整保留")
func pipeOutputCaptureHandlesWouldBlock() throws {
  let pipe = Pipe()
  let capture = try PipeOutputCapture(handle: pipe.fileHandleForReading, maximumBytes: 16) {}
  let callback = try #require(pipe.fileHandleForReading.readabilityHandler)
  callback(pipe.fileHandleForReading)
  try pipe.fileHandleForWriting.write(contentsOf: Data("ready".utf8))
  callback(pipe.fileHandleForReading)
  let result = capture.finish()
  #expect(result.data == Data("ready".utf8))
  #expect(result.readError == nil)
  #expect(!result.exceededLimit)
}

@Test("退出收尾之后的迟到回调不再读取，也不改变最终输出")
func pipeOutputCaptureIgnoresRetiredCallback() throws {
  let pipe = Pipe()
  let capture = try PipeOutputCapture(handle: pipe.fileHandleForReading, maximumBytes: 64) {}
  // 保留已调度的真实 handler：设置 nil 不能撤回这个回调。
  let retired = try #require(pipe.fileHandleForReading.readabilityHandler)
  try pipe.fileHandleForWriting.write(contentsOf: Data("before".utf8))
  #expect(capture.finish().data == Data("before".utf8))
  try pipe.fileHandleForWriting.write(contentsOf: Data("after".utf8))
  retired(pipe.fileHandleForReading)
  let result = capture.finish()
  #expect(result.data == Data("before".utf8))
  #expect(result.readError == nil)
  var bytes = [UInt8](repeating: 0, count: 5)
  let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
  #expect(count == 5)
  #expect(bytes == Array("after".utf8))
}

@Test("可读回调和收尾并发时输出有序且不丢尾部数据")
func pipeOutputCaptureSerializesReadAndFinish() async throws {
  for _ in 0..<100 {
    let pipe = Pipe()
    let capture = try PipeOutputCapture(handle: pipe.fileHandleForReading, maximumBytes: 4096) {}
    let callback = try #require(pipe.fileHandleForReading.readabilityHandler)
    let expected = Data((0..<2048).map { UInt8($0 % 251) })
    try pipe.fileHandleForWriting.write(contentsOf: expected)
    let result = await withTaskGroup(of: Void.self, returning: PipeOutputCapture.Result.self) {
      group in
      for _ in 0..<8 { group.addTask { callback(pipe.fileHandleForReading) } }
      let result = capture.finish()
      await group.waitForAll()
      return result
    }
    #expect(result.data == expected)
    #expect(result.readError == nil)
  }
}

@Test("有界输出区分恰好达到上限与真正超限，并检测退出时的尾部超限")
func pipeOutputCaptureDetectsLimitAtFinish() throws {
  for count in [4, 5] {
    let pipe = Pipe()
    let capture = try PipeOutputCapture(handle: pipe.fileHandleForReading, maximumBytes: 4) {}
    try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: count))
    let result = capture.finish()
    #expect(result.data == Data(repeating: 65, count: 4))
    #expect(result.exceededLimit == (count > 4))
    #expect(result.readError == nil)
  }
  let pipe = Pipe()
  #expect(throws: POSIXError(.EINVAL)) {
    try PipeOutputCapture(handle: pipe.fileHandleForReading, maximumBytes: 0) {}
  }
}

@Test("反复并发运行快速退出命令，孙进程仍握住写端时也不崩溃或丢输出")
func processRunnerConcurrentFastExitsPreserveOutput() async {
  await withTaskGroup(of: Void.self) { group in
    for worker in 0..<8 {
      group.addTask {
        for iteration in 0..<25 {
          let expected = "worker-\(worker)-\(iteration)"
          let output = MemoryProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "printf \(expected); sleep 0.05 &"],
            maximumBytes: 8192)
          #expect(output == expected)
        }
      }
    }
  }
}

@Test("超时和取消仍返回失败，不遗留等待输出的线程")
func processRunnerTimeoutAndCancellationRemainBounded() async throws {
  let started = ContinuousClock.now
  let timeout = await Task.detached {
    MemoryProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
  }.value
  #expect(timeout == nil)
  let task = Task.detached {
    MemoryProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 10)
  }
  try await Task.sleep(for: .milliseconds(50))
  task.cancel()
  #expect(await task.value == nil)
  #expect(ContinuousClock.now - started < .seconds(3))
}

@Test("记忆提炼与工作区检查的实际执行器保持输出限制")
func processOutputLimitsApplyToExtractionAndInspection() async {
  let extraction = await Task.detached {
    MemoryExtractionProcess.run(
      executable: "/usr/bin/head", arguments: ["-c", "262145", "/dev/zero"],
      workingDirectory: nil, timeout: 5)
  }.value
  #expect(extraction?.standardOutput.utf8.count == MemoryExtractionProcess.maximumOutputBytes)
  #expect(extraction?.didTimeOut == true)
  let inspection = await Task.detached {
    WorkspaceInspectionService.runForTesting(
      executable: "/usr/bin/yes", arguments: ["bounded"], timeout: 2, maximumBytes: 1024)
  }.value
  #expect(inspection.utf8.count == 1024)
}
