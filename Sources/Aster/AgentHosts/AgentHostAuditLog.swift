// agent 主机访问审计的落盘：按月一个 JSONL 文件，只追加；目录 0700、文件 0600；
// 保留 13 个月；同时镜像到 os_log（命令按 private 处理）。写失败只记诊断，不阻断执行。
import AsterCore
import Foundation
import os

/// 审计写入的抽象；测试注入内存实现。
@MainActor
protocol AgentHostAuditWriting: AnyObject {
  func append(_ record: AgentHostAuditRecord)
}

/// 审计日志。写入在串行后台队列，调用方（主线程）只负责组装记录。
@MainActor
final class AgentHostAuditLog: AgentHostAuditWriting {
  static let shared = AgentHostAuditLog()
  /// 保留期：13 个月。审计常在几个月后才被问到，宁长勿短。
  nonisolated static let retentionMonths = 13
  nonisolated static let filePrefix = "agent-hosts-"

  let directory: URL
  private let queue = DispatchQueue(label: "io.aster.agent-hosts.audit", qos: .utility)
  private let logger = Logger(subsystem: "io.local.aster", category: "agent-hosts")
  /// 写失败的上报出口；测试替换。
  var onWriteFailure: @MainActor (Error) -> Void = { error in
    DiagnosticsCenter.shared.record("agent_hosts.audit_write_failed", level: .error, category: .storage, error: error)
  }

  /// 默认目录 `~/Library/Application Support/Aster/audit`。
  init(directory: URL = AgentHostAuditLog.defaultDirectory()) {
    self.directory = directory
  }

  static func defaultDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Aster/audit", isDirectory: true)
  }

  /// 追加一条记录。os_log 里命令与原因按 private 标注，只在本机调试时可见。
  func append(_ record: AgentHostAuditRecord) {
    logger.notice(
      "\(record.action.rawValue, privacy: .public) host=\(record.host?.name ?? "-", privacy: .public) command=\(record.command ?? "-", privacy: .private)"
    )
    let directory = directory
    queue.async { [weak self] in
      do {
        try Self.write(record, to: directory)
      } catch {
        Task { @MainActor in self?.onWriteFailure(error) }
      }
    }
  }

  /// 等后台队列里已排队的写入完成（测试与退出前用）。
  func flush() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }

  /// 后台：确保目录与权限，按月文件追加一行。
  nonisolated private static func write(_ record: AgentHostAuditRecord, to directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let url = directory.appendingPathComponent(fileName(for: Date()))
    if !manager.fileExists(atPath: url.path) {
      guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(record)
    line.append(0x0A)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  /// `agent-hosts-YYYY-MM.jsonl`（本地时区的年月）。
  nonisolated static func fileName(for date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month], from: date)
    return String(format: "%@%04d-%02d.jsonl", filePrefix, components.year ?? 0, components.month ?? 0)
  }

  // MARK: - 保留期

  /// 删除超过保留期的月文件。启动时在后台跑一次。
  func pruneExpired(now: Date = Date()) {
    let directory = directory
    queue.async {
      guard let cutoff = Calendar.current.date(byAdding: .month, value: -Self.retentionMonths, to: now),
        let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
      else { return }
      let cutoffName = Self.fileName(for: cutoff)
      for file in files where file.hasPrefix(Self.filePrefix) && file.hasSuffix(".jsonl") && file < cutoffName {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
      }
    }
  }

  // MARK: - 分页读取

  /// 一页审计记录（新到旧）。
  struct Page: Sendable {
    var records: [AgentHostAuditRecord]
    /// 下一页的游标（本页最后一条的 id）；nil 表示没有更早的了。
    var nextBefore: String?
  }

  /// 读取 `before`（记录 id）之前的至多 `limit` 条，新到旧；不可解析的行跳过。
  func page(before: String?, limit: Int) async -> Page {
    let directory = directory
    let limit = min(max(limit, 1), 50)
    return await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: Self.readPage(directory: directory, before: before, limit: limit)) }
    }
  }

  /// 后台：从最新的月文件往回读。文件小（一个月几千行量级），逐个整读即可。
  nonisolated static func readPage(directory: URL, before: String?, limit: Int) -> Page {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".jsonl") }
      .sorted(by: >)
    var records: [AgentHostAuditRecord] = []
    var skipping = before != nil
    let decoder = JSONDecoder()
    for file in files {
      guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(file).path) else { continue }
      for line in data.split(separator: 0x0A).reversed() {
        guard let record = try? decoder.decode(AgentHostAuditRecord.self, from: Data(line)) else { continue }
        if skipping {
          if record.id == before { skipping = false }
          continue
        }
        records.append(record)
        if records.count == limit + 1 {
          records.removeLast()
          return Page(records: records, nextBefore: records.last?.id)
        }
      }
    }
    return Page(records: records, nextBefore: nil)
  }
}
