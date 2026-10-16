import AsterCore
import Foundation

// 设置页「主机 → 已知主机」的桥接协作者：缓存最近一次 known_hosts 列表，执行 `hosts.knownHosts.*` 动作。
//
// known_hosts 的解析与改写只在 aster-ssh 里做；这里只决定问哪些文件和主机、校验删除请求
// 确实来自上一次列表里的可写文件，并在记录已变化（stale）时提示用户重新加载。
// 由 `SettingsHostsBridge` 持有，快照放在 `hosts.knownHosts` 下。

/// 「已知主机」页的状态与动作处理。
@MainActor
final class SettingsKnownHostsBridge {
  /// 外部依赖。生产用 `.live()`；测试注入假的列出 / 删除实现。
  struct Dependencies {
    /// 运行 `aster-ssh known-hosts list`。
    var list: @Sendable (SSHKnownHostsListRequest) async throws -> SSHKnownHostsListing
    /// 运行 `aster-ssh known-hosts remove`。
    var remove: @Sendable (SSHKnownHostsRemoveRequest) async throws -> SSHKnownHostsRemoveResult

    /// 生产依赖：定位打包的 aster-ssh；找不到时两项都抛 `SSHBrokerError.executableMissing`。
    static func live() -> Dependencies {
      Dependencies(
        list: { request in
          guard let tool = SSHRuntimeTool.located() else { throw SSHBrokerError.executableMissing }
          return try await tool.listKnownHosts(request)
        },
        remove: { request in
          guard let tool = SSHRuntimeTool.located() else { throw SSHBrokerError.executableMissing }
          return try await tool.removeKnownHost(request)
        })
    }
  }

  /// 列表状态。`loaded` 之后再次加载时保留旧列表，页面不会闪成空白。
  enum State: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  private let dependencies: Dependencies
  /// 已保存主机与没有绑定主机的旧机器 target；每次加载时读取。
  private let hosts: @MainActor () -> [SSHHostProfile]
  private let machineTargets: @MainActor () -> [String]

  /// 状态变化后推送新快照。
  var pushSnapshot: () -> Void = {}
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }

  private(set) var state: State = .idle
  /// 最近一次成功的列表与它对应的主机名对照。
  private(set) var listing: SSHKnownHostsListing?
  private var names: [SSHHostPort: [String]] = [:]
  /// 加载代次：较早发起、较晚返回的结果直接丢弃，不覆盖新结果。
  private var generation = 0
  /// 正在执行的删除；同一时刻只允许一个，避免两次删除基于同一份旧行号。
  private var isRemoving = false

  init(
    dependencies: Dependencies,
    hosts: @escaping @MainActor () -> [SSHHostProfile],
    machineTargets: @escaping @MainActor () -> [String]
  ) {
    self.dependencies = dependencies
    self.hosts = hosts
    self.machineTargets = machineTargets
  }

  // MARK: - 快照

  /// 快照的 `knownHosts` 字段：`state`、`error`、`files`、`entries`（带 `names` 与 `removable`）、`skipped`。
  func snapshot() -> [String: Any] {
    var object: [String: Any] = ["state": stateName]
    if case .failed(let message) = state { object["error"] = message }
    guard let listing else { return object }
    let writable = Set(listing.files.filter(\.writable).map(\.path))
    object["files"] = listing.files.map { file in
      var row: [String: Any] = [
        "path": Self.displayPath(file.path), "rawPath": file.path, "exists": file.exists,
        "writable": file.writable, "global": file.global,
      ]
      row["error"] = file.error
      return row
    }
    object["entries"] = listing.entries.map { entry in
      var row: [String: Any] = [
        "file": entry.file, "line": entry.line, "hosts": entry.hosts, "hashed": entry.hashed,
        "algorithm": entry.algorithm, "fingerprint": entry.fingerprint, "lineDigest": entry.lineDigest,
        "matches": entry.matches.map { ["host": $0.host, "port": $0.port] as [String: Any] },
        // 每个命中主机对应的已保存主机名；没有名称的跳板或旧机器地址为空数组。
        "names": entry.matches.map { names[$0] ?? [] },
        "removable": writable.contains(entry.file),
      ]
      row["marker"] = entry.marker
      row["comment"] = entry.comment
      return row
    }
    object["skipped"] = listing.skipped.map {
      ["file": $0.file, "line": $0.line, "reason": $0.reason] as [String: Any]
    }
    return object
  }

  /// 状态的网页名。
  private var stateName: String {
    switch state {
    case .idle: "idle"
    case .loading: "loading"
    case .loaded: "loaded"
    case .failed: "error"
    }
  }

  /// 家目录下的路径写成 `~/…`，只用于显示。
  static func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  // MARK: - 动作

  /// 分发 `hosts.knownHosts.` 前缀的动作；返回 false 表示不是本组动作。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) -> Bool {
    switch action {
    case "hosts.knownHosts.refresh":
      refresh(complete: complete)
    case "hosts.knownHosts.remove":
      remove(payload, complete: complete)
    default:
      return false
    }
    return true
  }

  /// 重新列出 known_hosts。先推一份 loading 快照，结果回来后再推一次。
  func refresh(complete: @escaping (Bool) -> Void = { _ in }) {
    generation += 1
    let current = generation
    let query = SSHKnownHostsQuery.request(hosts: hosts(), machineTargets: machineTargets())
    state = .loading
    pushSnapshot()
    let list = dependencies.list
    Task { @MainActor [weak self] in
      let result: Result<SSHKnownHostsListing, Error>
      do { result = .success(try await list(query.request)) } catch { result = .failure(error) }
      guard let self, current == self.generation else {
        complete(false)
        return
      }
      switch result {
      case .success(let listing):
        self.listing = listing
        self.names = query.names
        self.state = .loaded
        self.pushSnapshot()
        complete(true)
      case .failure(let error):
        self.state = .failed(Self.describe(error))
        self.pushSnapshot()
        complete(false)
      }
    }
  }

  /// 删除一条记录或其中一个主机模式。只接受上一次列表里出现过、且所在文件可写的记录。
  private func remove(_ payload: [String: Any], complete: @escaping (Bool) -> Void) {
    guard !isRemoving else {
      complete(false)
      return
    }
    let request: SSHKnownHostsRemoveRequest
    do { request = try validatedRemoveRequest(payload) } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    isRemoving = true
    let remove = dependencies.remove
    Task { @MainActor [weak self] in
      let result: Result<SSHKnownHostsRemoveResult, Error>
      do { result = .success(try await remove(request)) } catch { result = .failure(error) }
      guard let self else {
        complete(false)
        return
      }
      self.isRemoving = false
      switch result {
      case .success:
        self.toast(L("已从 known_hosts 删除"), false)
        complete(true)
      case .failure(SSHKnownHostsToolError.stale):
        self.toast(L("这条记录已在别处被修改，列表已重新加载"), true)
        complete(false)
      case .failure(let error):
        self.toast(Self.describe(error), true)
        complete(false)
      }
      // 不论成败都重新列出：行号会变，旧列表不能再用于下一次删除。
      self.refresh()
    }
  }

  /// 把网页 payload 还原成删除请求，并确认它对应上一次列表里一条可写文件中的记录。
  func validatedRemoveRequest(_ payload: [String: Any]) throws -> SSHKnownHostsRemoveRequest {
    guard let file = payload["file"] as? String, let line = payload["line"] as? Int,
      let digest = payload["lineDigest"] as? String, let listing
    else { throw SettingsKnownHostsError.invalidPayload }
    guard listing.files.contains(where: { $0.path == file && $0.writable }) else {
      throw SettingsKnownHostsError.notWritable
    }
    guard let entry = listing.entries.first(where: { $0.file == file && $0.line == line && $0.lineDigest == digest })
    else { throw SettingsKnownHostsError.unknownEntry }
    var host: SSHHostPort?
    if let raw = payload["host"] as? [String: Any] {
      guard let name = raw["host"] as? String, let port = raw["port"] as? Int else {
        throw SettingsKnownHostsError.invalidPayload
      }
      // 只删列表里显示过的命中主机，网页不能随意指定别的模式。
      let candidate = SSHHostPort(host: name, port: port)
      guard entry.matches.contains(candidate) else { throw SettingsKnownHostsError.unknownEntry }
      host = candidate
    }
    return SSHKnownHostsRemoveRequest(file: file, line: line, lineDigest: digest, host: host)
  }

  /// 把错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SettingsKnownHostsError: return error.message
    case SSHKnownHostsToolError.stale: return L("这条记录已在别处被修改，请重新加载")
    case SSHKnownHostsToolError.failed(let code):
      switch code {
      case "global": return L("系统级 known_hosts 文件是只读的")
      case "notWritable": return L("这个 known_hosts 文件不可写")
      case "notFound": return L("known_hosts 文件不存在")
      case "noMatch": return L("这一行里没有这台主机")
      default: return L("无法修改 known_hosts：\(code)")
      }
    case SSHKnownHostsToolError.malformedOutput: return L("aster-ssh 返回了无法识别的结果")
    case SSHRuntimeToolError.timedOut: return L("读取 known_hosts 超时")
    case SSHBrokerError.executableMissing: return L("找不到 aster-ssh，请重新构建 Aster.app")
    default: return L("无法读取 known_hosts：\(error.localizedDescription)")
    }
  }
}

/// 「已知主机」动作在边界被拒绝的原因。
enum SettingsKnownHostsError: Error, Equatable {
  case invalidPayload
  case notWritable
  case unknownEntry

  var message: String {
    switch self {
    case .invalidPayload: L("known_hosts 参数无效")
    case .notWritable: L("这个 known_hosts 文件不可写")
    case .unknownEntry: L("找不到这条记录，请重新加载列表")
    }
  }
}
