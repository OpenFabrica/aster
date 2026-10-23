import AsterCore
import Foundation

/// App 侧受管终端编排。
///
/// 职责边界（`docs/developer/remote-work.md` §3.1）：本类型只做机器配置解析、连接
/// 编排和会话投影；服务协议细节留在 `AsterCore` 的会话客户端里，`TerminalSession`
/// 只看到“引用 + 桥命令”。
///
/// P8.8 起，全新终端默认走受管路径（Local 后台服务）。打包 App 自动从 Bundle 内
/// 解析 aster-session 二进制并使用 ~/Library/Application Support/Aster/Sessions/
/// （开发版在 `Aster-Dev` 下）作为状态父目录。环境变量仍可覆盖（测试与开发场景）。
/// 升级用户保留旧终端直至显式迁移。
@MainActor
final class ManagedTerminalCoordinator {
  /// 进程级共享实例。测试用独立配置替换它，避免污染用户默认终端策略。
  static var shared = ManagedTerminalCoordinator()

  /// 运行时二进制路径的环境变量；专用测试配置用它指定本次验收使用的产物。
  static let binaryEnvironmentKey = "ASTER_SESSION_BINARY"
  /// 私有状态父目录的环境变量；必须已存在且只对当前用户开放。
  static let stateDirectoryEnvironmentKey = "ASTER_SESSION_STATE_DIR"
  /// 命名会话名；缺省为 default。
  static let sessionNameEnvironmentKey = "ASTER_SESSION_NAME"

  private let client: any ManagedSessionClient
  private let environment: [String: String]
  /// 本协调器绑定的机器配置 ID（P4.2）。
  ///
  /// 默认是 Local，因此 `shared` 与 P2/P3 完全同义；远端协调器由注册表按机器传入，
  /// 使它产出的 `ManagedTerminalReference` 天然带正确的机器身份，跨机器对账不会串。
  let machineProfileID: UUID
  private var lifecycle = ManagedTerminalLifecycleTracker()
  /// terminalID → 服务端上报的 Shell PID。只从实测状态写入，不做本地推断。
  private var shellProcessIdentifiers: [String: Int32] = [:]
  /// 最近一次成功握手的服务身份；用于识别冷重启。
  private(set) var serverIdentity: SessionServerIdentity?
  private(set) var connectionState: SessionConnectionState = .disconnected
  /// 最近一次连接失败原因，用于界面显示明确错误而不是静默回退。
  private(set) var lastError: String?
  /// 正在进行的连接。启动时每个恢复的 Pane 都会并发对账，共用一次连接：既避免两次
  /// 并发的服务替换互相停掉对方刚起的服务，也让「旧服务」提示只弹一次。
  private var inFlightConnect: Task<SessionServerIdentity?, Never>?
  /// 本次运行是否已就旧服务问过用户。选「以后再说」后本次运行不再问，下次启动再问。
  private var outdatedServerPromptAnswered = false

  /// 旧服务仍有终端在运行时问用户是否现在重启；参数为运行中的终端数，返回 true 表示重启。
  /// 测试替换它，避免弹出模态窗口。
  static var confirmOutdatedServerRestart: @MainActor (Int) async -> Bool = {
    ManagedServerRestartPrompt.run(runningTerminals: $0)
  }

  /// 远端 SSH target 的环境变量；设置后受管终端走 SSH 传输而不是本机传输。
  static let remoteTargetEnvironmentKey = "ASTER_REMOTE_SSH_TARGET"

  /// - Parameters:
  ///   - hostID: 远端机器绑定的已保存主机；原生引擎下用它连接，OpenSSH 下不参与。
  ///   - routing: 引擎路由；有原生端点时远端传输走 aster-ssh。
  init(
    client: (any ManagedSessionClient)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    machineProfileID: UUID = MachineProfile.localProfileID,
    hostID: UUID? = nil,
    routing: SSHEngineRouting = .shared
  ) {
    self.client =
      client
      ?? Self.makeClient(
        environment: environment, hostID: hostID, native: routing.nativeEndpoint)
    self.environment = environment
    self.machineProfileID = machineProfileID
  }

  /// 依据环境选择传输实现。
  ///
  /// target 解析失败时**不回退到本机传输**：那会让用户以为连上了远端，实际在本机
  /// 建进程。这里保留本机客户端只是为了让协调器仍能构造，真正的拒绝发生在
  /// `remoteTransport` 为 nil 时——此时 `endpoint` 也不会被使用。
  ///
  /// 原生端点非 nil 时走 aster-ssh，不创建私有 OpenSSH 配置。
  private static func makeClient(
    environment: [String: String], hostID: UUID?, native: NativeSSHEndpoint?
  ) -> any ManagedSessionClient {
    guard let raw = environment[remoteTargetEnvironmentKey], !raw.isEmpty,
      let target = try? RemoteSSHTarget.parse(raw)
    else { return LocalManagedSessionClient() }
    let policy = RemoteSSHPolicy.fromEnvironment(environment)
    if let native {
      return RemoteManagedSessionClient(
        transport: RemoteSessionTransport(
          target: target, policy: policy, native: native, hostID: hostID))
    }
    // 私有临时配置只在 manage_ssh_config 开启时创建；关闭时直接用用户 OpenSSH 配置。
    let managed =
      policy.manageSSHConfig
      ? try? RemoteSSHConfigurationManager.makePrivateConfiguration(policy: policy) : nil
    return RemoteManagedSessionClient(
      transport: RemoteSessionTransport(
        target: target, policy: policy, managedConfiguration: managed))
  }

  /// 当前是否为远端受管模式。界面据此禁用本机文件类操作（P3.7）。
  var isRemote: Bool { client is RemoteManagedSessionClient }

  /// 远端机器显示名；本机模式返回 nil。
  var remoteMachineLabel: String? {
    (client as? RemoteManagedSessionClient)?.transport.target.rawText
  }

  /// 远端受管模式的 SSH 传输参数；本机模式返回 nil。
  ///
  /// 详情面板的旁路查询用它生成 argv，从而复用受管终端已经建立的连接（OpenSSH 的
  /// ControlMaster 或 aster-ssh broker），不需要用户再认证一次。返回的是值类型副本，调用方不能借它改传输状态。
  var remoteTransport: RemoteSessionTransport? {
    (client as? RemoteManagedSessionClient)?.transport
  }

  /// 服务端上报的受管 Shell 进程号。仅用于诊断与远端 `readlink /proc/<pid>/cwd`
  /// 兜底，不作为资源身份：进程重建后 `terminalID` 也会换新。
  func shellProcessIdentifier(for reference: ManagedTerminalReference) -> Int32? {
    shellProcessIdentifiers[reference.terminalID]
  }

  /// 记录一次服务端状态里的 PID。终端已退出时清掉，避免把回收后的号码交给远端脚本。
  private func noteShellProcessIdentifier(_ status: ManagedTerminalStatus) {
    switch status.state {
    case .running:
      if let pid = status.pid, pid > 0 { shellProcessIdentifiers[status.reference.terminalID] = pid }
    case .exited, .unavailable:
      shellProcessIdentifiers.removeValue(forKey: status.reference.terminalID)
    }
  }

  /// 当前服务缺失的可选能力提示（P3.7）。没有缺失或未握手时返回 nil。
  var unavailableCapabilityMessage: String? {
    guard let identity = serverIdentity else { return nil }
    guard
      case .compatible(let missing) = RemoteCompatibilityCheck.evaluate(
        protocolMajor: RemoteProtocolContract.clientProtocolMajor,
        capabilities: identity.capabilities)
    else { return nil }
    return RemoteCompatibilityCheck.unavailableActionMessage(missingOptional: missing)
  }

  /// 受管模式端点。环境变量优先；缺失时 Local 从 App Bundle 自动解析。
  ///
  /// 自动解析仅在打包 App 中生效（Bundle 含 aster-session）。状态目录
  /// 自动创建在 ~/Library/Application Support/Aster/Sessions/（开发版在 `Aster-Dev` 下），权限 0700。
  var endpoint: ManagedSessionEndpoint? {
    // 环境变量显式指定时直接使用（测试、开发、远端协调器）。
    if let binary = environment[Self.binaryEnvironmentKey], !binary.isEmpty,
      let stateParent = environment[Self.stateDirectoryEnvironmentKey], !stateParent.isEmpty
    {
      return ManagedSessionEndpoint(
        machineProfileID: machineProfileID,
        binaryPath: binary,
        stateParentPath: stateParent,
        sessionName: environment[Self.sessionNameEnvironmentKey] ?? "default"
      )
    }
    // Local 模式下从 App Bundle 自动发现 aster-session。
    guard machineProfileID == MachineProfile.localProfileID else { return nil }
    guard let resolved = Self.resolvedLocalEndpoint else { return nil }
    return resolved
  }

  /// 从 App Bundle 自动解析的 Local 端点。仅在打包 App 内且二进制存在时返回非 nil。
  private static let resolvedLocalEndpoint: ManagedSessionEndpoint? = {
    // aster-session 必须在 Contents/MacOS/ 里，和 Aster 主程序同目录。
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "app" else { return nil }
    let binary = bundle.appendingPathComponent("Contents/MacOS/aster-session").path
    guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
    // 状态目录按身份分开：开发版与正式版各起一个后台会话服务，开发版换服务时
    // 不会结束正式版的终端。
    let stateParent = AsterAppIdentity.current.applicationSupportDirectory()
      .appendingPathComponent("Sessions").path
    // 确保目录存在且权限正确（0700）。
    do {
      try FileManager.default.createDirectory(
        atPath: stateParent, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: stateParent)
    } catch {
      return nil
    }
    return ManagedSessionEndpoint(
      machineProfileID: MachineProfile.localProfileID,
      binaryPath: binary,
      stateParentPath: stateParent,
      sessionName: "default"
    )
  }()

  /// 本机后台会话服务的状态父目录（App Bundle 内运行时）；客户端主题色写在这里。
  static var localStateParentPath: String? { resolvedLocalEndpoint?.stateParentPath }

  var isEnabled: Bool { endpoint != nil }

  /// 端点是否由环境变量显式指定（测试、开发、远端协调器）。显式指定视为用户明确要求
  /// 托管；只有从 App Bundle 自动解析的 Local 端点才受「本机后台保活」开关约束。
  var endpointIsExplicit: Bool {
    guard let binary = environment[Self.binaryEnvironmentKey], !binary.isEmpty,
      let stateParent = environment[Self.stateDirectoryEnvironmentKey], !stateParent.isEmpty
    else { return false }
    return true
  }

  /// 该机器的布局事务客户端（P4.2）。受管模式未开启时返回 nil。
  ///
  /// 事务与受管终端必须共用同一条传输：拆成两个客户端很容易在本机/SSH 之间配错，
  /// 结果是结构提交到一台机器、终端创建在另一台。
  var transactionClient: WorkspaceTransactionClient? {
    guard let endpoint else { return nil }
    return WorkspaceTransactionClient(client: client, endpoint: endpoint)
  }

  /// 异步连接。把阻塞的服务查询挪出主线程。
  ///
  /// P3 起同一个协调器要驱动 SSH 传输，每次调用都是一次网络往返；在 MainActor 上
  /// 同步等待会卡住整个界面。本机实现也走同一条异步路径，避免两条传输出现两套时序。
  /// 并发调用共用同一次连接，见 `inFlightConnect`。
  @discardableResult
  func connectAsync() async -> SessionServerIdentity? {
    if let inFlightConnect { return await inFlightConnect.value }
    let task = Task { await performConnect() }
    inFlightConnect = task
    let identity = await task.value
    inFlightConnect = nil
    return identity
  }

  /// 一次真正的连接：后台握手；旧服务仍有终端在运行时先问用户，同意才替换。
  private func performConnect() async -> SessionServerIdentity? {
    guard let endpoint else {
      connectionState = .disabled
      return nil
    }
    connectionState = .connecting
    let client = self.client
    var outcome = await Self.detached { try Self.establish(client, endpoint) }
    // 用户回答之前不放行对账：其它 Pane 都在等这次连接，不会先挂到马上要停的旧服务上。
    if case .success(let attachment) = outcome, attachment.outdatedRunningTerminals > 0,
      !outdatedServerPromptAnswered, let local = client as? LocalManagedSessionClient
    {
      outdatedServerPromptAnswered = true
      if await Self.confirmOutdatedServerRestart(attachment.outdatedRunningTerminals) {
        outcome = await Self.detached {
          ManagedServerAttachment(identity: try local.replaceServer(endpoint))
        }
      }
    }
    switch outcome {
    case .success(let attachment):
      serverIdentity = attachment.identity
      connectionState = .online
      lastError = nil
      return attachment.identity
    case .failure(let error):
      connectionState = .attention
      lastError = String(describing: error)
      return nil
    }
  }

  /// 在后台线程执行阻塞的服务调用，把结果或错误带回调用方。
  nonisolated private static func detached<Value: Sendable>(
    _ body: @escaping @Sendable () throws -> Value
  ) async -> Result<Value, any Error> {
    await Task.detached(priority: .userInitiated) { Result { try body() } }.value
  }

  /// 确保服务在运行并取回身份。本机服务额外核对登录会话与构建号：活过注销的服务直接
  /// 替换；升级前留下的旧服务没有终端在运行时直接替换，否则在结果里标出，由调用方问用户。
  /// 远端服务按原样附加（远端没有本机桌面会话的概念，升级走远端安装事务）。
  nonisolated private static func establish(
    _ client: any ManagedSessionClient, _ endpoint: ManagedSessionEndpoint
  ) throws -> ManagedServerAttachment {
    if let local = client as? LocalManagedSessionClient {
      let bundled = ManagedSessionServerBuild.bundled(binaryPath: endpoint.binaryPath, client: local)
      return try local.ensureCurrentServer(endpoint, bundledBuild: bundled)
    }
    _ = try client.ensureServer(endpoint)
    return ManagedServerAttachment(identity: try client.serverStatus(endpoint))
  }

  /// 异步创建受管终端。失败向上抛出，调用方必须显示明确错误。
  func createTerminalAsync(workingDirectory: String, argv: [String]) async throws
    -> ManagedTerminalStatus
  {
    guard let endpoint else { throw ManagedSessionError.runtimeUnavailable("managed mode disabled") }
    if serverIdentity == nil { _ = await connectAsync() }
    guard connectionState == .online else {
      throw ManagedSessionError.runtimeUnavailable(lastError ?? "server unavailable")
    }
    let client = self.client
    let status = try await Task.detached(priority: .userInitiated) {
      try client.createTerminal(endpoint, workingDirectory: workingDirectory, argv: argv)
    }.value
    noteShellProcessIdentifier(status)
    return status
  }

  /// 异步对账持久化引用与服务端实测状态。
  func reconcileAsync(
    references: [ManagedTerminalReference],
    persistedServerEpoch: String?
  ) async -> [ManagedTerminalReference: ManagedTerminalResolution] {
    guard let endpoint else {
      return Dictionary(
        uniqueKeysWithValues: references.map {
          ($0, ManagedTerminalResolution.unreachable($0, reason: "managed mode disabled"))
        })
    }
    let identity = await connectAsync()
    let client = self.client
    let live = await Task.detached(priority: .userInitiated) {
      (try? client.listTerminals(endpoint)) ?? []
    }.value
    live.forEach(noteShellProcessIdentifier)
    return ManagedTerminalReconciler.reconcile(
      references: references,
      liveTerminals: live,
      currentServer: identity?.reference,
      currentServerEpoch: identity?.serverEpoch,
      persistedServerEpoch: persistedServerEpoch,
      unreachableReason: identity == nil ? (lastError ?? "server unavailable") : nil
    )
  }

  /// 连接（必要时启动）本地默认后台服务。Local 允许首次使用时自动启动或附加。
  ///
  /// 同步版本保留给必须在返回前完成的关闭路径（`stop()`/`terminate`）；
  /// 交互路径一律用 `connectAsync()`。
  /// 关闭路径不弹窗：旧服务仍有终端在运行时这里照常附加，不替换。
  @discardableResult
  func connect() -> SessionServerIdentity? {
    guard let endpoint else {
      connectionState = .disabled
      return nil
    }
    connectionState = .connecting
    do {
      let identity = try Self.establish(client, endpoint).identity
      serverIdentity = identity
      connectionState = .online
      lastError = nil
      return identity
    } catch {
      connectionState = .attention
      lastError = String(describing: error)
      return nil
    }
  }

  /// 创建一个受管终端并返回稳定引用。失败向上抛出，调用方必须显示明确错误，
  /// 不允许静默回退成未经标识的新本地 Shell。
  func createTerminal(workingDirectory: String, argv: [String]) throws -> ManagedTerminalStatus {
    guard let endpoint else { throw ManagedSessionError.runtimeUnavailable("managed mode disabled") }
    if serverIdentity == nil { _ = connect() }
    guard connectionState == .online else {
      throw ManagedSessionError.runtimeUnavailable(lastError ?? "server unavailable")
    }
    let status = try client.createTerminal(
      endpoint, workingDirectory: workingDirectory, argv: argv)
    noteShellProcessIdentifier(status)
    return status
  }

  /// 查询该会话全部受管终端的真实状态。
  func liveTerminals() throws -> [ManagedTerminalStatus] {
    guard let endpoint else { throw ManagedSessionError.runtimeUnavailable("managed mode disabled") }
    let live = try client.listTerminals(endpoint)
    live.forEach(noteShellProcessIdentifier)
    return live
  }

  /// 重开 App 后对账持久化引用与服务端实测状态。
  func reconcile(
    references: [ManagedTerminalReference],
    persistedServerEpoch: String?
  ) -> [ManagedTerminalReference: ManagedTerminalResolution] {
    guard endpoint != nil else {
      return Dictionary(
        uniqueKeysWithValues: references.map {
          ($0, ManagedTerminalResolution.unreachable($0, reason: "managed mode disabled"))
        })
    }
    let identity = connect()
    let live = (try? liveTerminals()) ?? []
    return ManagedTerminalReconciler.reconcile(
      references: references,
      liveTerminals: live,
      currentServer: identity?.reference,
      currentServerEpoch: identity?.serverEpoch,
      persistedServerEpoch: persistedServerEpoch,
      unreachableReason: identity == nil ? (lastError ?? "server unavailable") : nil
    )
  }

  /// 结束受管终端：这是资源关闭语义，会结束远端进程。
  @discardableResult
  func terminate(_ reference: ManagedTerminalReference) -> ManagedTerminalStatus? {
    guard let endpoint else { return nil }
    guard let status = try? client.terminateTerminal(endpoint, terminalID: reference.terminalID)
    else { return nil }
    // 真实结束由服务端上报；这里进入去重器，保证只写一次结束事件。
    _ = lifecycle.handle(.serverReportedEnd(status))
    shellProcessIdentifiers.removeValue(forKey: reference.terminalID)
    return status
  }

  /// 异步结束受管终端：语义与 `terminate` 相同，但阻塞的 `terminal terminate` 子进程往返
  /// 放在后台线程，供关 Pane 这类必须立即响应的界面路径使用。
  @discardableResult
  func terminateAsync(_ reference: ManagedTerminalReference) async -> ManagedTerminalStatus? {
    guard let endpoint else { return nil }
    let client = self.client
    let terminalID = reference.terminalID
    let result = await Task.detached(priority: .userInitiated) {
      try? client.terminateTerminal(endpoint, terminalID: terminalID)
    }.value
    guard let status = result else { return nil }
    _ = lifecycle.handle(.serverReportedEnd(status))
    shellProcessIdentifiers.removeValue(forKey: terminalID)
    return status
  }

  /// 分离：只释放本客户端资源，服务端进程与布局保留，不写结束事件。
  func detach(_ reference: ManagedTerminalReference) {
    _ = lifecycle.handle(.clientDetached(reference))
  }

  /// 服务端上报的真实结束是否应写入录制层；重复上报返回 false。
  func shouldRecordEnd(for status: ManagedTerminalStatus) -> Bool {
    if case .recordEnded = lifecycle.handle(.serverReportedEnd(status)) { return true }
    return false
  }

  /// 桥进程的启动描述：Ghostty 命令文本，以及创建 surface 时现取的附加环境。
  struct BridgeLaunch {
    let command: String
    /// 桥是 `aster-ssh client` 时每次调用签一张新的启动票据，其余为空。
    let environment: () -> [String: String]
  }

  /// 生成 Ghostty surface 的桥启动描述。
  ///
  /// surface 的子进程是桥而不是任务本身，关闭 surface 只结束桥，受管进程继续运行。
  /// `takeover` 让桥从别的客户端（例如另一个 Aster 实例）手里接管写租约。
  func bridgeLaunch(
    for reference: ManagedTerminalReference, readOnly: Bool = false, takeover: Bool = false
  ) -> BridgeLaunch? {
    guard let endpoint else { return nil }
    let arguments = client.bridgeArguments(
      endpoint, terminalID: reference.terminalID, readOnly: readOnly, takeover: takeover)
    // 桥的可执行文件由传输实现决定：本机是 aster-session 本身，SSH 是 /usr/bin/ssh 或 aster-ssh。
    let executable = client.bridgeExecutablePath(endpoint)
    return BridgeLaunch(
      command: GhosttyConfiguration.launchCommand(shell: executable, arguments: arguments),
      environment: {
        NativeSSHTicketing.launchEnvironment(executablePath: executable, arguments: arguments)
      })
  }

  /// 桥命令文本（`bridgeLaunch` 的命令部分）。
  func bridgeCommandText(
    for reference: ManagedTerminalReference, readOnly: Bool = false, takeover: Bool = false
  ) -> String? {
    bridgeLaunch(for: reference, readOnly: readOnly, takeover: takeover)?.command
  }

  /// 异步上传图片到远端受管会话（P7）。
  ///
  /// 在后台线程执行阻塞的上传调用，返回服务端路径。
  /// 受管模式未开启或 endpoint 缺失时返回 nil。
  func uploadImageAsync(
    terminalID: String,
    contentType: String,
    data: Data
  ) async throws -> String {
    guard let endpoint else {
      throw ManagedSessionError.runtimeUnavailable("managed mode disabled")
    }
    let client = self.client
    return try await Task.detached(priority: .userInitiated) {
      try client.uploadImage(
        endpoint, terminalID: terminalID, contentType: contentType, data: data)
    }.value
  }
}
