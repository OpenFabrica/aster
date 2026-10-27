// 内置原生工具的后台计算：文件 Hash 流式计算与取消、全机监听端口扫描能找到本进程刚开的端口。
import AsterCore
import Darwin
import Foundation
import Testing

@testable import Aster

struct BuiltinNativeBackgroundTests {
  /// 在临时目录写一个跨多个分块的文件，返回目录与文件。
  private func makeFile(bytes: Int) throws -> (directory: URL, file: URL, data: Data) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-builtin-hash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    let file = directory.appendingPathComponent("payload.bin")
    try data.write(to: file)
    return (directory, file, data)
  }

  @Test func fileHasherMatchesInMemoryHashesAcrossChunks() async throws {
    let fixture = try makeFile(bytes: BuiltinFileHasher.chunkSize * 2 + 12_345)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let lines = try await BuiltinFileHasher.hashes(ofFileAt: fixture.file) { _ in }
    #expect(lines == BuiltinTextTools.hashes(of: fixture.data))
    #expect(try await BuiltinFileHasher.fileSize(at: fixture.file) == Int64(fixture.data.count))
  }

  @Test func fileHasherReportsProgressForLargeFiles() async throws {
    let fixture = try makeFile(bytes: BuiltinFileHasher.chunkSize * 9)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let reported = ProgressLog()
    _ = try await BuiltinFileHasher.hashes(ofFileAt: fixture.file) { processed in await reported.append(processed) }
    #expect(await reported.values == [Int64(BuiltinFileHasher.chunkSize * 8)])
  }

  @Test func fileHasherRejectsDirectories() async throws {
    let fixture = try makeFile(bytes: 16)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    await #expect(throws: BuiltinFileHashError.isDirectory) {
      try await BuiltinFileHasher.fileSize(at: fixture.directory)
    }
  }

  @Test func fileHasherStopsWhenTaskIsCancelled() async throws {
    let fixture = try makeFile(bytes: BuiltinFileHasher.chunkSize * 3)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let file = fixture.file
    // 任务先取消自己再开始算，结果与调度先后无关。
    let result = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await BuiltinFileHasher.hashes(ofFileAt: file) { _ in }
    }.result
    #expect(throws: CancellationError.self) { try result.get() }
  }

  @Test func listeningPortScanFindsOwnListeningSocket() async throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0)
    try #require(listen(descriptor, 1) == 0)
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    try #require(named == 0)
    let port = Int(UInt16(bigEndian: actual.sin_port))

    #expect(BuiltinListeningPorts.livePIDs().contains(getpid()))
    let ports = await BuiltinListeningPorts.scan()
    let mine = BuiltinPortFilter.filtered(ports, port: port).filter { $0.processIdentifier == getpid() }
    #expect(mine.map(\.endpoint) == ["127.0.0.1:\(port)"])
  }
}

/// 进度回调的收集器：回调在并发执行器上发生，用 actor 串行记录。
private actor ProgressLog {
  private(set) var values: [Int64] = []

  func append(_ value: Int64) {
    values.append(value)
  }
}
