import AsterCore
import Foundation

// known_hosts 管理的 App 侧服务：列出、校验删除请求、执行删除，与界面形式无关。
//
// known_hosts 的解析与改写只在 aster-ssh 里做；这里只决定问哪些文件和主机、缓存最近一次列表，
// 确认删除请求来自上一次列表里的可写文件，并在记录已变化（stale）时提示用户、重新列出。
// 原生「主机 → 已知主机」页与设置页桥接 `SettingsKnownHostsBridge` 共用这一份逻辑。

/// 「已知主机」的状态与动作。
@MainActor
final class SSHKnownHostsService {
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

  /// 状态或列表变化后调用（界面重绘、桥接推快照）。
  var didChange: () -> Void = {}
  /// 显示一条提示；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }

  private(set) var state: State = .idle
  /// 最近一次成功的列表。
  private(set) var listing: SSHKnownHostsListing?
  /// 与 `listing` 同一次加载得到的 `host:port` → 已保存主机名对照。
  private var names: [SSHHostPort: [String]] = [:]
  /// 加载代次：较早发起、较晚返回的结果直接丢弃，不覆盖新结果。
  private var generation = 0
  /// 正在执行的删除；同一时刻只允许一个，避免两次删除基于同一份旧行号。
  private(set) var isRemoving = false

  /// 注入依赖与主机来源；主机和机器在每次加载时才读取，拿到的总是当时的值。
  init(
    dependencies: Dependencies,
    hosts: @escaping @MainActor () -> [SSHHostProfile],
    machineTargets: @escaping @MainActor () -> [String]
  ) {
    self.dependencies = dependencies
    self.hosts = hosts
    self.machineTargets = machineTargets
  }

  /// 生产实例：共享主机目录、机器编队里没有绑定主机的 target、打包的 aster-ssh。
  static func live() -> SSHKnownHostsService {
    SSHKnownHostsService(
      dependencies: .live(),
      hosts: { SSHHostDirectory.shared.hosts },
      machineTargets: { MachineFleetModel.shared.profiles.filter { $0.hostID == nil }.compactMap(\.sshTarget) })
  }

  // MARK: - 查询

  /// 某个命中主机对应的已保存主机名；没有名称的跳板或旧机器地址返回空数组。
  func names(for endpoint: SSHHostPort) -> [String] {
    names[endpoint] ?? []
  }

  /// 记录是否可删：只有上一次列表里可写文件中的记录可以。
  func isRemovable(_ entry: SSHKnownHostsListing.Entry) -> Bool {
    listing?.files.contains { $0.path == entry.file && $0.writable } == true
  }

  // MARK: - 动作

  /// 重新列出 known_hosts。先通知 loading，结果回来后再通知一次；列出在 aster-ssh 子进程里，不占主线程。
  func refresh(complete: @escaping (Bool) -> Void = { _ in }) {
    generation += 1
    let current = generation
    let query = SSHKnownHostsQuery.request(hosts: hosts(), machineTargets: machineTargets())
    state = .loading
    didChange()
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
        self.didChange()
        complete(true)
      case .failure(let error):
        self.state = .failed(Self.describe(error))
        self.didChange()
        complete(false)
      }
    }
  }

  /// 删除一条记录或其中一个主机模式。先按上一次列表校验；结果以 toast 说明，之后总是重新列出。
  func remove(_ request: SSHKnownHostsRemoveRequest, complete: @escaping (Bool) -> Void = { _ in }) {
    guard !isRemoving else {
      complete(false)
      return
    }
    let validated: SSHKnownHostsRemoveRequest
    do { validated = try self.validated(request) } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    isRemoving = true
    didChange()
    let remove = dependencies.remove
    Task { @MainActor [weak self] in
      let result: Result<SSHKnownHostsRemoveResult, Error>
      do { result = .success(try await remove(validated)) } catch { result = .failure(error) }
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

  /// 确认请求对应上一次列表里一条可写文件中的记录；指定主机时它必须是该记录显示过的命中主机。
  func validated(_ request: SSHKnownHostsRemoveRequest) throws -> SSHKnownHostsRemoveRequest {
    guard let listing else { throw SSHKnownHostsError.unknownEntry }
    guard listing.files.contains(where: { $0.path == request.file && $0.writable }) else {
      throw SSHKnownHostsError.notWritable
    }
    guard
      let entry = listing.entries.first(where: {
        $0.file == request.file && $0.line == request.line && $0.lineDigest == request.lineDigest
      })
    else { throw SSHKnownHostsError.unknownEntry }
    // 只删列表里显示过的命中主机，调用方不能随意指定别的模式。
    if let host = request.host, !entry.matches.contains(host) { throw SSHKnownHostsError.unknownEntry }
    return request
  }

  // MARK: - 文案

  /// 家目录下的路径写成 `~/…`，只用于显示。
  nonisolated static func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  /// 把错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    switch error {
    case let error as SSHKnownHostsError: return error.message
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

/// 「已知主机」删除请求在边界被拒绝的原因。
enum SSHKnownHostsError: Error, Equatable {
  case invalidPayload
  case notWritable
  case unknownEntry

  /// 给用户看的说明。
  var message: String {
    switch self {
    case .invalidPayload: L("known_hosts 参数无效")
    case .notWritable: L("这个 known_hosts 文件不可写")
    case .unknownEntry: L("找不到这条记录，请重新加载列表")
    }
  }
}
