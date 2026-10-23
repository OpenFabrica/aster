// agent 远程执行的编排：校验 → 解析主机 → 开关 → 授权（必要时等用户批准）→ 终端 → 执行 → 审计。
// 控制协议的 `host.*` 方法只是它的薄封装；这里不碰 AppKit 视图，便于用替身测试。
// 错误消息是给 agent 看的协议文本，与 AsterControlDispatcher 一样不走界面本地化；审计里的值同理。
import AsterCore
import Foundation

/// `$ASTER_PANE_ID` 的解析结果：Pane 显示 ID、Pane UUID（停靠用），以及其中 agent 的 provider / session ID。
typealias AgentHostCallerPane = (pane: String, paneUUID: UUID, provider: AgentProvider?, agentSessionID: String?)

/// agent 远程执行服务。
@MainActor
final class AgentHostService {
  /// 外部依赖；测试注入替身。
  struct Dependencies {
    var hosts: @MainActor () -> [SSHHostProfile]
    var isEnabled: @MainActor () -> Bool
    var grants: AgentHostGrantStore
    var approvals: any AgentHostApprovalPresenting
    var registry: AgentHostTerminalRegistry
    var audit: any AgentHostAuditWriting
    var user: AgentHostLocalUser
    var now: () -> Date = Date.init
    /// 批准等待上限：Codex 的工具调用默认 60 秒超时，留出余量。
    var approvalTimeout: Duration = .seconds(50)
    /// 把 `$ASTER_PANE_ID` 解析成 Pane（显示 ID 与 UUID）与其中 agent 的 provider / session ID。
    var resolvePane: @MainActor (String) -> AgentHostCallerPane? = { _ in nil }
    /// 按 agent 自报的会话 ID 找正在跑它的 Pane；没有 `$ASTER_PANE_ID` 时（Codex）的退路。
    var resolveAgentSessionPane: @MainActor (String) -> AgentHostCallerPane? = { _ in nil }
  }

  /// 生产实例；App 启动时装配，控制协议从这里取。
  static var shared: AgentHostService?

  let dependencies: Dependencies
  var grants: AgentHostGrantStore { dependencies.grants }
  var registry: AgentHostTerminalRegistry { dependencies.registry }

  /// 每条命令的审计上下文：结束时写 `exec.finished` 要用。
  private struct CommandContext {
    var caller: AgentHostResolvedCaller
    var host: AgentHostAuditRecord.HostReference
    var approver: AgentHostAuditRecord.Approver
    var command: String
    var reason: String?
    var pendingRecorded = false
  }

  private var commandContexts: [String: CommandContext] = [:]

  /// 一次授权的结论：审计依据，以及命令没敲进去时要退还的 once 授权。
  private struct Authorization {
    var approver: AgentHostAuditRecord.Approver
    /// 退还用：从授权簿消耗的 once 授权，或用户当场「允许一次」对应的授权（尚未入簿）。
    var refundableOnce: AgentHostGrant?
    /// `refundableOnce` 已在簿里存在过（被消耗），退还时原样放回、不写新建审计。
    var onceWasStored = false
    /// 等过用户批准：后续连接改用新的期限。
    var waitedForUser = false
  }

  /// 批准之后，连接与执行至少还有这么久（批准常常吃掉大半期限）。
  static let postApprovalMinimum: Duration = .seconds(30)
  /// 但最多比原期限多出这么久：CLI 与 MCP 客户端只比 `timeout_ms` 多等 15 秒，超出就会先断开。
  static let postApprovalGrace: Duration = .seconds(10)

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
    dependencies.registry.onCommandFinished = { [weak self] terminal, result in
      self?.recordFinished(terminal: terminal, result: result)
    }
    dependencies.approvals.onAnswer = { [weak self] request, answer, hadLiveWaiters in
      self?.applyAnswer(request, answer: answer, hadLiveWaiters: hadLiveWaiters)
    }
    dependencies.grants.onRevoked = { [weak self] revoked in self?.closeTerminals(revoked: revoked) }
  }

  // MARK: - 方法

  /// `host.exec`。命令没能敲进终端（连接失败、排队超时、暂停）时退还 once 授权，重试不用再问。
  func exec(_ params: HostExecParams) async throws -> HostExecResult {
    let timeout = Duration.milliseconds(AgentHostValidation.clampedTimeout(params.timeoutMs))
    var deadline = ContinuousClock.now + timeout
    let caller = resolveCaller(params.agent)
    let (profile, resolved) = try resolveHost(params.host)
    let authorization = try await authorize(
      caller: caller, profile: profile, resolved: resolved, command: params.command, reason: params.reason,
      deadline: deadline)
    if authorization.waitedForUser { deadline = Self.postApprovalDeadline(original: deadline, timeout: timeout) }
    let approver = authorization.approver
    let host = hostReference(profile, resolved)
    let commandID = Self.makeIdentifier(prefix: "c")
    var started = false
    do {
      let terminal = try obtainTerminal(caller: caller, profile: profile, resolved: resolved)
      try await terminal.waitUntilReady(deadline: deadline)
      let result = try await terminal.execute(
        command: params.command, commandID: commandID, deadline: deadline,
        maximumOutputBytes: params.maxOutputBytes ?? AgentHostLimits.defaultMaximumOutputBytes
      ) {
        started = true
        commandContexts[commandID] = CommandContext(
          caller: caller, host: host, approver: approver, command: params.command, reason: params.reason)
        dependencies.audit.append(
          AgentHostAuditRecord(
            time: dependencies.now(), action: .execStarted, actor: caller.auditActor, approver: approver,
            host: host, commandID: commandID, terminalID: terminal.terminalID, command: params.command,
            reason: params.reason))
      }
      recordPendingIfNeeded(result)
      return result
    } catch {
      if !started { refund(authorization) }
      throw error
    }
  }

  /// `host.open`：批准后建立（或复用）终端并等就绪。
  func open(_ params: HostOpenParams) async throws -> HostTerminalInfo {
    let timeout = Duration.milliseconds(AgentHostValidation.clampedTimeout(params.timeoutMs))
    var deadline = ContinuousClock.now + timeout
    let caller = resolveCaller(params.agent)
    let (profile, resolved) = try resolveHost(params.host)
    let authorization = try await authorize(
      caller: caller, profile: profile, resolved: resolved, command: nil, reason: nil, deadline: deadline)
    if authorization.waitedForUser { deadline = Self.postApprovalDeadline(original: deadline, timeout: timeout) }
    let terminal = try obtainTerminal(caller: caller, profile: profile, resolved: resolved)
    try await terminal.waitUntilReady(deadline: deadline)
    return terminal.info
  }

  /// 批准之后的新期限：剩余时间不足 `postApprovalMinimum` 时补足，但不超过原期限加
  /// `postApprovalGrace`，也不超过从现在起的请求超时。
  static func postApprovalDeadline(
    original: ContinuousClock.Instant, timeout: Duration, now: ContinuousClock.Instant = .now
  ) -> ContinuousClock.Instant {
    min(max(original, now + postApprovalMinimum), original + postApprovalGrace, now + timeout)
  }

  /// `host.wait`：只有发起会话能等自己的命令；别人的 command_id 一律 not_found。
  func wait(_ params: HostWaitParams) async throws -> HostExecResult {
    let deadline = ContinuousClock.now + .milliseconds(AgentHostValidation.clampedTimeout(params.timeoutMs))
    let caller = resolveCaller(params.agent)
    guard let terminal = registry.terminal(commandID: params.commandID), terminal.sessionKey == caller.key else {
      throw AsterControlError(code: .notFound, message: "找不到命令 \(params.commandID)")
    }
    let result = try await terminal.wait(
      commandID: params.commandID, deadline: deadline,
      maximumOutputBytes: params.maxOutputBytes ?? AgentHostLimits.defaultMaximumOutputBytes,
      sinceEpisode: terminal.needsInputEpisode(of: params.commandID))
    recordPendingIfNeeded(result)
    return result
  }

  /// `host.read`：本会话终端的活动屏幕。读屏也要求总开关开着：关掉开关就不该再能看远端屏幕。
  func read(_ params: HostReadParams) throws -> HostReadResult {
    try ensureEnabled()
    let terminal = try ownedTerminal(host: params.host, terminalID: params.terminalID, caller: resolveCaller(params.agent))
    return HostReadResult(
      terminalID: terminal.terminalID, text: terminal.read(lines: params.lines ?? AgentHostLimits.defaultReadLines))
  }

  /// `host.interrupt`：按 command_id 或主机找到本会话的终端，发 Ctrl-C。
  func interrupt(_ params: HostInterruptParams) async throws -> HostExecResult {
    let caller = resolveCaller(params.agent)
    let terminal: AgentHostTerminal
    if let commandID = params.commandID {
      guard let found = registry.terminal(commandID: commandID), found.sessionKey == caller.key,
        found.runningCommandID == commandID
      else { throw AsterControlError(code: .notFound, message: "找不到运行中的命令 \(commandID)") }
      terminal = found
    } else {
      terminal = try ownedTerminal(host: params.host, terminalID: nil, caller: caller)
    }
    return try await terminal.interrupt(maximumOutputBytes: AgentHostLimits.defaultMaximumOutputBytes)
  }

  /// `host.close`。
  func close(_ params: HostCloseParams) throws {
    let terminal = try ownedTerminal(host: params.host, terminalID: params.terminalID, caller: resolveCaller(params.agent))
    registry.close(terminal)
  }

  /// `host.terminals`：只列调用方本会话的终端，不提供跨会话列表（见 HostTerminalsParams）。
  func terminals(_ params: HostTerminalsParams) -> HostTerminalsResult {
    let key = resolveCaller(params.agent).key
    return HostTerminalsResult(terminals: registry.terminals.filter { $0.sessionKey == key }.map(\.info))
  }

  // MARK: - 生命周期

  /// 总开关被关掉：撤掉所有挂起的批准，关掉所有 agent 终端（之后连读屏也不行）。
  func handleAccessDisabled() {
    dependencies.approvals.dismissAll(hostID: nil)
    registry.closeAll()
  }

  /// 主机列表变化：主机被删或连接目标（地址、用户、端口、跳板）变了，撤掉针对旧目标的批准面板；
  /// 用户此时点批准，批准的已不是面板上那个目标。
  func handleHostsChanged() {
    let current = currentFingerprints()
    dependencies.approvals.dismiss { current[$0.hostID] != $0.targetFingerprint }
  }

  /// 每台已保存主机当前的目标指纹；解析失败的主机不在结果里。
  func currentFingerprints() -> [UUID: String] {
    let all = dependencies.hosts()
    var result: [UUID: String] = [:]
    for profile in all where !profile.isDefaults {
      do {
        result[profile.id] = Self.fingerprint(try SSHHostResolver.resolve(profile.id, in: all))
      } catch {
        continue
      }
    }
    return result
  }

  /// `host.list` 的 `agentAccess`：只算指纹仍与当前目标一致的 always 授权。
  func alwaysGrantedHostIDs() -> Set<UUID> {
    grants.alwaysGrantedHostIDs(currentFingerprints: currentFingerprints())
  }

  /// 用户撤销授权后关掉失去依据的终端：撤销 always 关这台主机的全部终端，
  /// 撤销 session / once 只关该会话在这台主机上的终端。
  private func closeTerminals(revoked: [AgentHostGrant]) {
    for grant in revoked {
      for terminal in registry.terminals
      where terminal.hostID == grant.hostID && (grant.scope == .always || terminal.sessionKey == grant.sessionKey) {
        registry.close(terminal)
      }
    }
  }

  // MARK: - 授权

  /// 开关 → 暂停 → 授权簿 → 必要时弹批准面板（有期限地等）→ 复核目标 → 暂停。
  ///
  /// 暂停检查放在授权簿之前：被暂停时不能白白消耗一次性授权。批准之后再查一遍暂停，
  /// 用户可能在等批准时按了暂停；此时把已消耗的 once 授权退回去。
  private func authorize(
    caller: AgentHostResolvedCaller, profile: SSHHostProfile, resolved: SSHResolvedSpec, command: String?,
    reason: String?, deadline: ContinuousClock.Instant
  ) async throws -> Authorization {
    try ensureEnabled()
    try ensureNotPaused(caller: caller, hostID: profile.id)
    let fingerprint = Self.fingerprint(resolved)
    var authorization: Authorization
    switch await grants.evaluate(hostID: profile.id, sessionKey: caller.key, fingerprint: fingerprint, command: command) {
    case .allowed(let grant):
      authorization = Authorization(
        approver: .grant(grant), refundableOnce: grant.scope == .once ? grant : nil, onceWasStored: true)
    case .deniedRecently:
      throw AsterControlError(code: .approvalDenied, message: "用户拒绝了 agent 访问 \(profile.name)，冷却期内不再询问")
    case .needsApproval:
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else {
        throw AsterControlError(code: .approvalPending, message: "等待用户批准")
      }
      let request = AgentHostApprovalRequest(
        caller: caller, hostID: profile.id, hostName: profile.name, target: resolved.credentialEndpoint,
        reason: reason, command: command, targetFingerprint: fingerprint)
      guard
        let answer = try await dependencies.approvals.requestApproval(
          request, timeout: min(remaining, dependencies.approvalTimeout))
      else {
        throw AsterControlError(code: .approvalPending, message: "用户还没有在 Aster 里回答批准请求，稍后重试")
      }
      let scope: AgentHostGrantScope
      switch answer {
      case .deny:
        throw AsterControlError(code: .approvalDenied, message: "用户拒绝了 agent 访问 \(profile.name)")
      case .allowOnce: scope = .once
      case .allowSession: scope = .session
      case .allowAlways: scope = .always
      }
      let approval = approvalGrant(request, scope: scope)
      try verifyTargetUnchanged(request, approval: approval)
      authorization = Authorization(
        approver: .user(account: dependencies.user.account, scope: scope),
        refundableOnce: scope == .once ? approval : nil, waitedForUser: true)
    }
    do {
      try ensureNotPaused(caller: caller, hostID: profile.id)
    } catch {
      refund(authorization)
      throw error
    }
    return authorization
  }

  /// 总开关。
  private func ensureEnabled() throws {
    guard dependencies.isEnabled() else {
      throw AsterControlError(
        code: .agentAccessDisabled, message: "设置里没有允许编程 agent 申请主机访问（设置 → 主机 → Agent 访问）")
    }
  }

  /// 用户在面板里暂停了这个会话在这台主机上的 agent。
  private func ensureNotPaused(caller: AgentHostResolvedCaller, hostID: UUID) throws {
    if registry.terminal(sessionKey: caller.key, hostID: hostID)?.isPaused == true {
      throw AsterControlError(code: .agentPaused, message: "用户已在 Aster 窗口里暂停 agent")
    }
  }

  /// 批准后复核：等待期间主机被删或连接目标变了，这次批准作废（写 `grant.invalidated`）。
  private func verifyTargetUnchanged(_ request: AgentHostApprovalRequest, approval: AgentHostGrant) throws {
    let current = currentFingerprints()[request.hostID]
    guard current != request.targetFingerprint else { return }
    grants.invalidateApproval(approval, currentFingerprint: current)
    throw AsterControlError(
      code: .hostNotReady,
      message: "等待批准期间主机 \(request.hostName) 的连接目标变了（或主机已删除），这次批准作废，请重新申请")
  }

  /// 命令没敲进终端：退还 once 授权。簿里取出的原样放回；当场「允许一次」的落成一条
  /// 一次性授权（写新建审计），5 分钟内同一会话重试同一条命令不用再问。
  private func refund(_ authorization: Authorization) {
    guard let grant = authorization.refundableOnce else { return }
    if authorization.onceWasStored {
      grants.restore(grant)
    } else {
      grants.add(grant, by: dependencies.user)
    }
  }

  /// 批准对应的授权条目：绑定发起时的目标指纹；once 还绑定命令。
  private func approvalGrant(_ request: AgentHostApprovalRequest, scope: AgentHostGrantScope) -> AgentHostGrant {
    let time = dependencies.now()
    return AgentHostGrant(
      hostID: request.hostID, scope: scope, sessionKey: request.caller.key, targetFingerprint: request.targetFingerprint,
      grantedAt: time, grantedBy: dependencies.user.account, lastUsedAt: time, command: request.command)
  }

  /// 用户回答批准面板：先让回答生效（授权或冷却），等待方随后被唤醒。
  ///
  /// 授权绑定请求发起时的目标指纹，不在回答时重新解析：用户批准的是面板上显示的目标。
  /// 「允许一次」只有在所有等待方都已超时时才落成一次性授权（5 分钟内被该会话同一条命令消耗）；
  /// 有等待方时它直接放行，不留授权。主机已被删除时不落任何授权。
  private func applyAnswer(_ request: AgentHostApprovalRequest, answer: AgentHostApprovalAnswer, hadLiveWaiters: Bool) {
    let user = dependencies.user
    guard dependencies.hosts().contains(where: { $0.id == request.hostID }) else { return }
    switch answer {
    case .deny: grants.recordDenial(sessionKey: request.caller.key, hostID: request.hostID, by: user)
    case .allowOnce: if !hadLiveWaiters { grants.add(approvalGrant(request, scope: .once), by: user) }
    case .allowSession: grants.add(approvalGrant(request, scope: .session), by: user)
    case .allowAlways: grants.add(approvalGrant(request, scope: .always), by: user)
    }
  }

  // MARK: - 终端

  /// 取或建本会话在该主机上的终端。
  private func obtainTerminal(
    caller: AgentHostResolvedCaller, profile: SSHHostProfile, resolved: SSHResolvedSpec
  ) throws -> AgentHostTerminal {
    let terminal = try registry.obtain(
      AgentHostTerminalSpec(
        terminalID: Self.makeIdentifier(prefix: "t"), hostID: profile.id, hostName: profile.name,
        target: resolved.credentialEndpoint, caller: caller))
    if terminal.state == .ended {
      throw AsterControlError(code: .terminalEnded, message: "agent 终端已结束")
    }
    return terminal
  }

  /// 本会话的终端：按主机或 terminal_id 找；别的会话的终端当作不存在。
  private func ownedTerminal(host: String?, terminalID: String?, caller: AgentHostResolvedCaller) throws -> AgentHostTerminal {
    let terminal: AgentHostTerminal?
    if let terminalID {
      terminal = registry.terminal(id: terminalID)
    } else if let host {
      terminal = registry.terminal(sessionKey: caller.key, hostID: try resolveHost(host).0.id)
    } else {
      terminal = nil
    }
    guard let terminal, terminal.sessionKey == caller.key else {
      throw AsterControlError(code: .notFound, message: "本会话在该主机上没有 agent 终端")
    }
    return terminal
  }

  // MARK: - 审计

  /// 命令返回时仍未结束：记一次 `exec.pending`（每条命令只记一次）。
  private func recordPendingIfNeeded(_ result: HostExecResult) {
    guard result.status == .running || result.status == .needsInput,
      var context = commandContexts[result.commandID], !context.pendingRecorded
    else { return }
    context.pendingRecorded = true
    commandContexts[result.commandID] = context
    dependencies.audit.append(
      AgentHostAuditRecord(
        time: dependencies.now(), action: .execPending, actor: context.caller.auditActor,
        approver: context.approver, host: context.host, commandID: result.commandID,
        terminalID: result.terminalID, command: context.command, reason: context.reason,
        result: .init(status: result.status, exitCode: nil, durationMs: result.durationMs,
          outputBytes: result.output.utf8.count)))
  }

  /// 命令真正结束（含之后才结束的 pending 命令）：写 `exec.finished`。
  private func recordFinished(terminal: AgentHostTerminal, result: AgentHostCommandTracker.Finished) {
    guard let context = commandContexts.removeValue(forKey: result.id) else { return }
    dependencies.audit.append(
      AgentHostAuditRecord(
        time: dependencies.now(), action: .execFinished, actor: context.caller.auditActor,
        approver: context.approver, host: context.host, commandID: result.id, terminalID: terminal.terminalID,
        command: context.command, reason: context.reason,
        result: .init(status: result.status, exitCode: result.exitCode, durationMs: result.durationMs,
          outputBytes: result.output.utf8.count)))
  }

  // MARK: - 解析

  /// 主机：UUID 或精确名称；默认项不算；重名 → `ambiguous_target`。
  func resolveHost(_ text: String) throws -> (SSHHostProfile, SSHResolvedSpec) {
    let all = dependencies.hosts()
    let saved = all.filter { !$0.isDefaults }
    let matches: [SSHHostProfile]
    if let id = UUID(uuidString: text), let profile = saved.first(where: { $0.id == id }) {
      matches = [profile]
    } else {
      matches = saved.filter { $0.name == text }
    }
    guard matches.count <= 1 else {
      throw AsterControlError(code: .ambiguousTarget, message: "有 \(matches.count) 台主机叫 \(text)，请改用主机 ID")
    }
    guard let profile = matches.first else {
      throw AsterControlError(code: .notFound, message: "找不到主机 \(text)")
    }
    do {
      return (profile, try SSHHostResolver.resolve(profile.id, in: all))
    } catch {
      throw AsterControlError(code: .hostNotReady, message: "主机配置无法解析：\(String(describing: error))")
    }
  }

  /// 有效会话键：调用方给的 session，再并入调用 Pane 里 agent 的 provider 与 session ID。
  /// 新开的 Claude 会话因此不会继承旧会话的「本会话允许」。
  ///
  /// 调用方 Pane 先按 `$ASTER_PANE_ID` 找；找不到再按 agent 自报的会话 ID 找。Codex 启动 MCP server
  /// 时滤掉了环境变量，还可能让多个会话共用一个 MCP 进程，只有会话 ID 能分清是哪个 Pane。
  func resolveCaller(_ caller: AgentHostCaller) -> AgentHostResolvedCaller {
    var resolved = AgentHostResolvedCaller(key: caller.session, session: caller.session, client: caller.client)
    let pane =
      caller.callerPane.flatMap { dependencies.resolvePane($0) }
      ?? caller.agentSession.flatMap { dependencies.resolveAgentSessionPane($0) }
    if let pane {
      resolved.pane = pane.pane
      resolved.paneUUID = pane.paneUUID
      resolved.provider = pane.provider
      resolved.agentSessionID = pane.agentSessionID
      if let provider = pane.provider {
        resolved.key = "\(caller.session)#\(provider.rawValue):\(pane.agentSessionID ?? "-")"
      }
    }
    return resolved
  }

  /// 目标指纹：地址、用户、端口与整条跳板链。
  static func fingerprint(_ spec: SSHResolvedSpec) -> String {
    var chain: [String] = []
    var next = spec.jump
    while let box = next {
      chain.append(box.spec.credentialEndpoint)
      next = box.spec.jump
    }
    return AgentHostTargetFingerprint.make(host: spec.host, user: spec.user, port: spec.port, jumpChain: chain)
  }

  private func hostReference(_ profile: SSHHostProfile, _ resolved: SSHResolvedSpec) -> AgentHostAuditRecord.HostReference {
    .init(id: profile.id.uuidString, name: profile.name, target: resolved.credentialEndpoint)
  }

  /// `c-` / `t-` 加 12 位十六进制。
  static func makeIdentifier(prefix: String) -> String {
    "\(prefix)-\(AgentHostCommandFraming.makeNonce())"
  }
}
