import AsterCore
import Combine
import Foundation

// 主机系统信息的 App 侧权威入口：读写 host-facts.json、按主机触发采集、发布变化。
// 采集只在两个时机发生：原生 SSH 连接建立后（信息缺失或过期才采）与用户在主机页点「刷新系统信息」。
// 采集走 broker 共享连接上的一次非交互 exec，不往用户的终端里敲命令。

/// 主机系统信息目录。
@MainActor
final class SSHHostFactsDirectory: ObservableObject {
  static let shared = SSHHostFactsDirectory()

  /// 超过这么久的信息在下次连接时重新采集。
  static let staleAfter: TimeInterval = 24 * 60 * 60

  /// 当前已采集的信息，按主机 ID。
  @Published private(set) var facts: [UUID: SSHHostSystemFacts]
  /// 正在采集的主机，主机页可据此显示状态。
  @Published private(set) var inFlight: Set<UUID> = []

  let store: SSHHostFactsStore
  /// 跑探测脚本并返回原始输出；生产走 aster-ssh / OpenSSH，测试注入固定输出。
  private let collector: @Sendable (UUID) async throws -> String
  private let now: () -> Date

  init(
    store: SSHHostFactsStore = SSHHostFactsStore(),
    collector: (@Sendable (UUID) async throws -> String)? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.store = store
    self.collector = collector ?? Self.liveCollector
    self.now = now
    facts = store.load()
  }

  func facts(for id: UUID) -> SSHHostSystemFacts? { facts[id] }

  /// broker 报告连接建立：这台主机没有信息或信息过期时采一次。
  func handleLinkState(_ event: SSHLinkStateEvent) {
    guard event.state == .connected, let hostID = event.hostID else { return }
    if let existing = facts[hostID], now().timeIntervalSince(existing.collectedAt) < Self.staleAfter { return }
    Task { await collectQuietly(hostID: hostID) }
  }

  /// 采集一台主机的信息并落盘。同一台主机采集中时直接返回当前值；失败抛错，由调用方决定是否提示。
  @discardableResult
  func refresh(hostID: UUID) async throws -> SSHHostSystemFacts {
    guard !inFlight.contains(hostID) else {
      if let existing = facts[hostID] { return existing }
      throw SSHHostFactsError.inProgress
    }
    inFlight.insert(hostID)
    defer { inFlight.remove(hostID) }
    let output = try await collector(hostID)
    guard let parsed = SSHHostSystemProbe.parse(output, at: now()) else { throw SSHHostFactsError.malformed }
    var next = facts
    next[hostID] = parsed
    try store.save(next)
    facts = next
    return parsed
  }

  /// 连接建立后的自动采集：失败只记诊断，不打扰用户。
  private func collectQuietly(hostID: UUID) async {
    do { try await refresh(hostID: hostID) } catch {
      DiagnosticsCenter.shared.record(
        "hosts.facts.collect_failed", level: .warning, category: .storage, error: error)
    }
  }

  /// 删除已不存在主机的信息。
  func prune(keepingIDs ids: Set<UUID>) {
    let next = facts.filter { ids.contains($0.key) }
    guard next.count != facts.count else { return }
    do { try store.save(next) } catch {
      DiagnosticsCenter.shared.record("hosts.facts.prune_failed", level: .warning, category: .storage, error: error)
    }
    facts = next
  }

  /// 生产采集：按主机规格建传输（原生引擎用 `--host-id` 走 broker 共享连接，OpenSSH 回退时
  /// 用合并默认项后的 target 与用户自己的 ssh 配置），非交互执行探测脚本。
  /// `RemoteSSHProcessRunner.run` 是阻塞调用，放到后台任务里。
  private static let liveCollector: @Sendable (UUID) async throws -> String = { hostID in
    let transport = try await MainActor.run { () throws -> RemoteSessionTransport in
      let hosts = SSHHostDirectory.shared.hosts
      let raw = try MachineFleetModel.openSSHTarget(forHost: hostID, in: hosts)
      return RemoteSessionTransport(
        target: try RemoteSSHTarget.parse(raw),
        policy: RemoteSSHPolicy.fromEnvironment(ProcessInfo.processInfo.environment),
        native: SSHEngineRouting.shared.nativeEndpoint, hostID: hostID)
    }
    let arguments = transport.sshArguments(remoteCommand: SSHHostSystemProbe.probeCommand())
    let runner = transport.makeProcessRunner()
    return try await Task.detached {
      let result = try runner.run(arguments: arguments, timeout: SSHHostSystemProbe.timeout)
      guard result.exitStatus == 0 || SSHHostSystemProbe.parse(result.standardOutput) != nil else {
        throw SSHHostFactsError.commandFailed(result.exitStatus)
      }
      return result.standardOutput
    }.value
  }
}

/// 采集失败的原因。
enum SSHHostFactsError: Error, Equatable {
  /// 这台主机已经在采集中。
  case inProgress
  /// 输出里没有探测标记：脚本没跑起来，或远端没有 POSIX sh。
  case malformed
  /// 远端命令退出码非零且没有可用输出。
  case commandFailed(Int32)

  var message: String {
    switch self {
    case .inProgress: L("正在采集这台主机的系统信息")
    case .malformed: L("没有读到系统信息，远端可能没有 /bin/sh")
    case .commandFailed(let status): L("采集系统信息失败（退出码 \(String(status))）")
    }
  }
}
