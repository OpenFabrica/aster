// agent 远程执行的编排：校验 → 解析主机 → 开关 → 授权（必要时等用户批准）→ 终端 → 执行 → 审计。
// 控制协议的 `host.*` 方法只是它的薄封装；这里不碰 AppKit 视图，便于用替身测试。
// 错误消息是给 agent 看的协议文本，与 AsterControlDispatcher 一样不走界面本地化；审计里的值同理。
import AsterCore
import Foundation

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
    /// 把 `$ASTER_PANE_ID` 解析成 Pane 显示 ID 与其中 agent 的 provider / session ID。
    var resolvePane: @MainActor (String) -> (pane: String, provider: AgentProvider?, agentSessionID: String?)? = { _ in nil }
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

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
    dependencies.registry.onCommandFinished = { [weak self] terminal, result in
      self?.recordFinished(terminal: terminal, result: result)
    }
    dependencies.approvals.onAnswer = { [weak self] request, answer, hadLiveWaiters in
      self?.applyAnswer(request, answer: answer, hadLiveWaiters: hadLiveWaiters)
    }
  }

  // MARK: - 方法

  /// `host.exec`。
  func exec(_ params: HostExecParams) async throws -> HostExecResult {
    let deadline = ContinuousClock.now + .milliseconds(AgentHostValidation.clampedTimeout(params.timeoutMs))
    let caller = resolveCaller(params.agent)
    let (profile, resolved) = try resolveHost(params.host)
    let approver = try await authorize(
      caller: caller, profile: profile, resolved: resolved, command: params.command, reason: params.reason,
      deadline: deadline)
    let terminal = try obtainTerminal(caller: caller, profile: profile, resolved: resolved)
    try await terminal.waitUntilReady(deadline: deadline)
    let commandID = Self.makeIdentifier(prefix: "c")
    let host = hostReference(profile, resolved)
    let result = try await terminal.execute(
      command: params.command, commandID: commandID, deadline: deadline,
      maximumOutputBytes: params.maxOutputBytes ?? AgentHostLimits.defaultMaximumOutputBytes
    ) {
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
  }

  /// `host.open`：批准后建立（或复用）终端并等就绪。
  func open(_ params: HostOpenParams) async throws -> HostTerminalInfo {
    let deadline = ContinuousClock.now + .milliseconds(AgentHostValidation.clampedTimeout(params.timeoutMs))
    let caller = resolveCaller(params.agent)
    let (profile, resolved) = try resolveHost(params.host)
    _ = try await authorize(
      caller: caller, profile: profile, resolved: resolved, command: nil, reason: nil, deadline: deadline)
    let terminal = try obtainTerminal(caller: caller, profile: profile, resolved: resolved)
    try await terminal.waitUntilReady(deadline: deadline)
    return terminal.info
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

  /// `host.read`：本会话终端的活动屏幕。
  func read(_ params: HostReadParams) throws -> HostReadResult {
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

  /// `host.terminals`：带 agent 时只列本会话的。
  func terminals(_ params: HostTerminalsParams) -> HostTerminalsResult {
    let key = params.agent.map { resolveCaller($0).key }
    return HostTerminalsResult(
      terminals: registry.terminals.filter { key == nil || $0.sessionKey == key }.map(\.info))
  }

  // MARK: - 授权

  /// 开关 → 授权簿 → 必要时弹批准面板（有期限地等）→ 暂停检查。返回审计用的批准依据。
  private func authorize(
    caller: AgentHostResolvedCaller, profile: SSHHostProfile, resolved: SSHResolvedSpec, command: String?,
    reason: String?, deadline: ContinuousClock.Instant
  ) async throws -> AgentHostAuditRecord.Approver {
    guard dependencies.isEnabled() else {
      throw AsterControlError(
        code: .agentAccessDisabled, message: "设置里没有允许编程 agent 申请主机访问（设置 → 主机 → Agent 访问）")
    }
    let approver: AgentHostAuditRecord.Approver
    switch await grants.evaluate(hostID: profile.id, sessionKey: caller.key, fingerprint: Self.fingerprint(resolved)) {
    case .allowed(let grant):
      approver = .grant(grant)
    case .deniedRecently:
      throw AsterControlError(code: .approvalDenied, message: "用户拒绝了这个 agent 会话访问 \(profile.name)")
    case .needsApproval:
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else {
        throw AsterControlError(code: .approvalPending, message: "等待用户批准")
      }
      let request = AgentHostApprovalRequest(
        caller: caller, hostID: profile.id, hostName: profile.name, target: resolved.credentialEndpoint,
        reason: reason, command: command)
      guard
        let answer = await dependencies.approvals.requestApproval(
          request, timeout: min(remaining, dependencies.approvalTimeout))
      else {
        throw AsterControlError(code: .approvalPending, message: "用户还没有在 Aster 里回答批准请求，稍后重试")
      }
      switch answer {
      case .deny:
        throw AsterControlError(code: .approvalDenied, message: "用户拒绝了这个 agent 会话访问 \(profile.name)")
      case .allowOnce: approver = .user(account: dependencies.user.account, scope: .once)
      case .allowSession: approver = .user(account: dependencies.user.account, scope: .session)
      case .allowAlways: approver = .user(account: dependencies.user.account, scope: .always)
      }
    }
    if registry.terminal(sessionKey: caller.key, hostID: profile.id)?.isPaused == true {
      throw AsterControlError(code: .agentPaused, message: "用户已在 Aster 窗口里暂停 agent")
    }
    return approver
  }

  /// 用户回答批准面板：先让回答生效（授权或冷却），等待方随后被唤醒。
  ///
  /// 「允许一次」只有在所有等待方都已超时时才落成一次性授权（5 分钟内被该会话下一次执行消耗）；
  /// 有等待方时它们直接放行，不留授权。
  private func applyAnswer(_ request: AgentHostApprovalRequest, answer: AgentHostApprovalAnswer, hadLiveWaiters: Bool) {
    let user = dependencies.user
    guard let profile = dependencies.hosts().first(where: { $0.id == request.hostID }),
      let resolved = try? SSHHostResolver.resolve(profile.id, in: dependencies.hosts())
    else { return }
    let time = dependencies.now()
    func grant(_ scope: AgentHostGrantScope) -> AgentHostGrant {
      AgentHostGrant(
        hostID: profile.id, scope: scope, sessionKey: request.caller.key,
        targetFingerprint: Self.fingerprint(resolved), grantedAt: time, grantedBy: user.account, lastUsedAt: time)
    }
    switch answer {
    case .deny: grants.recordDenial(sessionKey: request.caller.key, hostID: profile.id, by: user)
    case .allowOnce: if !hadLiveWaiters { grants.add(grant(.once), by: user) }
    case .allowSession: grants.add(grant(.session), by: user)
    case .allowAlways: grants.add(grant(.always), by: user)
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
  func resolveCaller(_ caller: AgentHostCaller) -> AgentHostResolvedCaller {
    var resolved = AgentHostResolvedCaller(key: caller.session, session: caller.session, client: caller.client)
    if let selector = caller.callerPane, let pane = dependencies.resolvePane(selector) {
      resolved.pane = pane.pane
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
