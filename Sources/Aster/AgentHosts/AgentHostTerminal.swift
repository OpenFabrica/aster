// 一个 agent 主机终端：连接就绪探测、命令排队与注入、轮询读屏推进命令状态、中断与关闭。
// 状态：connecting → ready ⇄ busy / needs_input → ended。全部在主线程，靠 200ms 轮询驱动，
// 不阻塞输入；等待方各自轮询并在自己的期限到达时返回。
import AsterCore
import Foundation

/// agent 主机终端。
@MainActor
final class AgentHostTerminal {
  /// 时序参数；测试缩短。
  struct Timing {
    var poll: Duration = .milliseconds(200)
    /// SSH 首次输出后静默多久才发就绪探针（等 motd 与提示符画完）。
    var connectQuiet: TimeInterval = 0.7
    /// 首次就绪探针的等待时间与重试次数。
    var probeTimeout: TimeInterval = 4
    var probeAttempts = 3
    /// 命令之间重新同步探针的等待时间。
    var resyncTimeout: TimeInterval = 3
    var needsInputQuiet: TimeInterval = 2
    var interruptGrace: TimeInterval = 1.5
    var scrollbackLines = 10_000
  }

  /// 排队上限：一个终端同时只跑一条命令，最多再排 4 条。
  static let maximumQueueDepth = 4

  let terminalID: String
  let hostID: UUID
  private(set) var hostName: String
  let target: String
  let sessionKey: String
  let caller: AgentHostResolvedCaller
  let surface: any AgentHostTerminalSurface
  private let timing: Timing
  private let now: () -> Date

  private(set) var state: HostTerminalState = .connecting { didSet { if state != oldValue { onChange?() } } }
  /// 用户在面板里暂停了 agent：新命令一律 `agent_paused`，已在跑的不受影响。
  var isPaused = false { didSet { if isPaused != oldValue { onChange?() } } }
  private(set) var lastActivity: Date
  /// 连接阶段的致命问题（非原生引擎、fish、探针无回应）；有值时等待方拿到 `host_not_ready`。
  private(set) var connectionError: String?
  /// 连接错误只是探针没回应（可能远端还在跑登录脚本），下一次请求可以再试一轮。
  private var connectionErrorRetryable = false
  private(set) var tracker: AgentHostCommandTracker

  /// 状态或运行中命令变化（面板刷新）。
  var onChange: (() -> Void)?
  /// 命令进入等输入：面板置前、请求注意、发通知。
  var onNeedsInput: ((String) -> Void)?
  /// 命令结束（任何结局），用于写审计。
  var onCommandFinished: ((AgentHostCommandTracker.Finished) -> Void)?
  /// 终端结束。
  var onEnded: (() -> Void)?

  private var monitorTask: Task<Void, Never>?
  private var hasSeenProcess = false
  private var queue: [UUID] = []
  private var needsResync = false
  private var lastScreenHash: Int?
  /// 连接阶段：最近一次屏幕内容、变化时间、已发探针。
  private var connectScreen: String?
  private var connectScreenChangedAt: Date
  private var probe: (nonce: String, sentAt: Date)?
  private var probeFailures = 0

  init(
    terminalID: String, hostID: UUID, hostName: String, target: String, sessionKey: String,
    caller: AgentHostResolvedCaller, surface: any AgentHostTerminalSurface,
    timing: Timing = Timing(), now: @escaping () -> Date = Date.init
  ) {
    self.terminalID = terminalID
    self.hostID = hostID
    self.hostName = hostName
    self.target = target
    self.sessionKey = sessionKey
    self.caller = caller
    self.surface = surface
    self.timing = timing
    self.now = now
    lastActivity = now()
    connectScreenChangedAt = now()
    tracker = AgentHostCommandTracker(needsInputQuiet: timing.needsInputQuiet, interruptGrace: timing.interruptGrace)
  }

  /// 开始轮询。重复调用无副作用。
  func start() {
    guard monitorTask == nil else { return }
    monitorTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        do { try await Task.sleep(for: self.timing.poll) } catch { return }
        self.step()
      }
    }
  }

  /// 主机改名后同步面板标题与结果里的名称。
  func updateHostName(_ name: String) {
    guard name != hostName else { return }
    hostName = name
    onChange?()
  }

  var runningCommandID: String? { tracker.running?.id }

  /// 协议投影。
  var info: HostTerminalInfo {
    HostTerminalInfo(
      terminalID: terminalID, hostID: hostID.uuidString, hostName: hostName, target: target,
      state: state, runningCommandID: tracker.running?.id)
  }

  // MARK: - 轮询

  /// 一步轮询：先看进程是否还在，再按状态推进连接或命令。
  private func step() {
    if surface.isProcessRunning {
      hasSeenProcess = true
    } else if hasSeenProcess {
      markEnded()
      return
    }
    switch state {
    case .connecting: connectStep()
    case .busy, .needsInput: commandStep()
    case .ready, .ended: break
    }
  }

  /// 前台进程已确认是原生 SSH 客户端。判断不了（nil）一律当作没确认：
  /// 宁可等到期限报 `host_not_ready`，也不往可能是本地 Shell 的 PTY 里敲字。
  private var isVerifiedNativeSSH: Bool { surface.isNativeSSHClient == true }

  /// 连接阶段：确认是原生 SSH 客户端，等首次输出静默后发探针，探针回应即就绪。
  private func connectStep() {
    guard connectionError == nil, let screen = surface.readActiveScreen() else { return }
    let current = now()
    if let probe {
      if AgentHostCommandFraming.containsProbeReply(screen, nonce: probe.nonce) {
        self.probe = nil
        probeFailures = 0
        lastScreenHash = screen.hashValue
        state = .ready
      } else if current.timeIntervalSince(probe.sentAt) >= timing.probeTimeout {
        self.probe = nil
        probeFailures += 1
        if Self.looksLikeFish(screen) {
          connectionError = "远端登录 Shell 是 fish，agent 远程执行只支持 POSIX Shell（bash、zsh、sh）。"
        } else if probeFailures >= timing.probeAttempts {
          connectionError = "终端没有回应就绪探针：远端可能不是 POSIX Shell，或正在等待输入。"
          connectionErrorRetryable = true
        }
      }
      return
    }
    guard !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    switch surface.isNativeSSHClient {
    case false?:
      // 引擎不可用时会回退成本地 Shell：命令会在本机执行，必须拒绝并立即结束这个终端，
      // 连预填好的 `ssh …` 也不留给任何人回车。下一次请求会新建终端重试。
      connectionError = "原生 SSH 引擎不可用，agent 命令不会在本地 Shell 中执行。"
      close()
      return
    case nil:
      // 还确认不了前台进程（pid 未知或 proc_pidpath 失败）：不发探针，继续等。
      return
    case true?:
      break
    }
    if screen != connectScreen {
      connectScreen = screen
      connectScreenChangedAt = current
    } else if current.timeIntervalSince(connectScreenChangedAt) >= timing.connectQuiet,
      !surface.isAlternateScreenActive
    {
      sendProbe(configureEnvironment: true, at: current)
    }
  }

  /// 发一次就绪探针；前台未确认是原生 SSH 客户端时不发。
  @discardableResult
  private func sendProbe(configureEnvironment: Bool, at time: Date) -> String? {
    let nonce = AgentHostCommandFraming.makeNonce()
    guard isVerifiedNativeSSH, surface.send(AgentHostCommandFraming.probeLine(nonce: nonce, configureEnvironment: configureEnvironment))
    else { return nil }
    probe = (nonce, time)
    return nonce
  }

  /// 命令阶段：推进跟踪器，处理完成、等输入与恢复。
  private func commandStep() {
    guard let screen = surface.readActiveScreen() else { return }
    let event = tracker.observe(screen: screen, now: now()) { [surface, timing] in
      surface.readScrollback(maximumLines: timing.scrollbackLines)
    }
    switch event {
    case .finished(let result)?:
      if result.status == .interrupted { needsResync = true }
      lastScreenHash = surface.readActiveScreen()?.hashValue
      lastActivity = now()
      state = .ready
      onCommandFinished?(result)
    case .needsInput(let prompt)?:
      state = .needsInput
      onNeedsInput?(prompt)
    case .resumed?:
      state = .busy
    case nil:
      break
    }
  }

  /// 终端结束：运行中命令记 `ended`，通知注册表。
  private func markEnded() {
    guard state != .ended else { return }
    monitorTask?.cancel()
    monitorTask = nil
    if let result = tracker.end(at: now(), scrollback: surface.readScrollback(maximumLines: timing.scrollbackLines)) {
      onCommandFinished?(result)
    }
    state = .ended
    onEnded?()
  }

  /// fish 解析期就拒绝 `$?`，错误行以 `fish:` 开头。
  static func looksLikeFish(_ screen: String) -> Bool {
    screen.contains("fish: ") || screen.contains("fish:")
  }

  // MARK: - 就绪

  /// 等到终端就绪或期限到达。重新连接失败过的终端会清掉探针失败计数再试一轮。
  func waitUntilReady(deadline: ContinuousClock.Instant) async throws {
    if connectionErrorRetryable {
      connectionError = nil
      connectionErrorRetryable = false
      probeFailures = 0
    }
    while state == .connecting {
      if let connectionError { throw AsterControlError(code: .hostNotReady, message: connectionError) }
      guard ContinuousClock.now < deadline else {
        throw AsterControlError(code: .hostNotReady, message: "SSH 终端还没就绪（仍在连接或等待认证），稍后重试。")
      }
      try await Task.sleep(for: timing.poll)
    }
    if state == .ended {
      if let connectionError { throw AsterControlError(code: .hostNotReady, message: connectionError) }
      throw AsterControlError(code: .terminalEnded, message: "agent 终端已结束")
    }
  }

  // MARK: - 执行

  /// 排队、必要时重新同步、敲入命令并等待结果（或期限到达）。
  ///
  /// 期限内轮不到 → `pane_busy`（点名挡路的命令）；排队超过 4 条 → `limit_exceeded`；
  /// 暂停 → `agent_paused`。期限到达但命令未结束不是错误：返回 `running` 与已有输出。
  func execute(
    command: String, commandID: String, deadline: ContinuousClock.Instant, maximumOutputBytes: Int,
    onStarted: () -> Void
  ) async throws -> HostExecResult {
    guard queue.count < Self.maximumQueueDepth else {
      throw AsterControlError(code: .limitExceeded, message: "该终端排队的命令已达 \(Self.maximumQueueDepth) 条")
    }
    let ticket = UUID()
    queue.append(ticket)
    defer { queue.removeAll { $0 == ticket } }
    while tracker.running != nil || queue.first != ticket {
      if state == .ended { throw AsterControlError(code: .terminalEnded, message: "agent 终端已结束") }
      guard ContinuousClock.now < deadline else {
        let blocker = tracker.running?.id ?? "排在前面的命令"
        throw AsterControlError(code: .paneBusy, message: "终端被 \(blocker) 占用，期限内没轮到")
      }
      try await Task.sleep(for: timing.poll)
    }
    guard !isPaused else {
      throw AsterControlError(code: .agentPaused, message: "用户已在 Aster 窗口里暂停 agent")
    }
    try ensureVerifiedNativeSSH()
    try await resynchronizeIfNeeded(deadline: deadline)
    try ensureVerifiedNativeSSH()
    let nonce = AgentHostCommandFraming.makeNonce()
    guard surface.send(AgentHostCommandFraming.commandLine(command: command, nonce: nonce)) else {
      throw AsterControlError(code: .paneBusy, message: "终端当前不接受输入（只读或本地导航模式）")
    }
    tracker.start(id: commandID, nonce: nonce, command: command, at: now())
    queue.removeAll { $0 == ticket }
    lastActivity = now()
    state = .busy
    onStarted()
    return try await wait(
      commandID: commandID, deadline: deadline, maximumOutputBytes: maximumOutputBytes, sinceEpisode: 0)
  }

  /// 每次往 PTY 敲命令前复核前台进程：连接中途回退或进程被换掉时绝不敲进去。
  private func ensureVerifiedNativeSSH() throws {
    guard isVerifiedNativeSSH else {
      throw AsterControlError(
        code: .hostNotReady, message: "无法确认终端前台是原生 SSH 客户端，agent 命令不会敲进去，稍后重试")
    }
  }

  /// 上次命令结束后屏幕被动过（用户打字、程序输出）或刚中断过：先发探针确认回到了提示符。
  private func resynchronizeIfNeeded(deadline: ContinuousClock.Instant) async throws {
    let screen = surface.readActiveScreen()
    guard needsResync || screen?.hashValue != lastScreenHash else { return }
    if surface.isAlternateScreenActive {
      throw AsterControlError(code: .paneBusy, message: "终端正在运行全屏程序（vim、less、top 等），先在 Aster 窗口里退出它")
    }
    guard let nonce = sendProbe(configureEnvironment: true, at: now()) else {
      throw AsterControlError(code: .paneBusy, message: "终端当前不接受输入（只读或本地导航模式）")
    }
    probe = nil
    let probeDeadline = min(deadline, ContinuousClock.now + .milliseconds(Int(timing.resyncTimeout * 1_000)))
    while ContinuousClock.now < probeDeadline {
      try await Task.sleep(for: timing.poll)
      if let text = surface.readActiveScreen(), AgentHostCommandFraming.containsProbeReply(text, nonce: nonce) {
        needsResync = false
        lastScreenHash = text.hashValue
        return
      }
    }
    if Self.looksLikeFish(surface.readActiveScreen() ?? "") {
      throw AsterControlError(code: .hostNotReady, message: "远端 Shell 是 fish，agent 远程执行只支持 POSIX Shell")
    }
    needsResync = true
    throw AsterControlError(
      code: .paneBusy, message: "终端没有回到 Shell 提示符（可能有程序在前台读输入），请在 Aster 窗口里处理后重试")
  }

  /// 等一条命令：完成、出现新一轮等输入，或期限到达（返回当前快照）。
  ///
  /// `sinceEpisode` 是调用方已知的等输入轮次；只有更新的一轮才提前返回，避免 agent
  /// 对同一个 sudo 提示反复轮询。
  func wait(
    commandID: String, deadline: ContinuousClock.Instant, maximumOutputBytes: Int, sinceEpisode: Int
  ) async throws -> HostExecResult {
    while true {
      if let finished = tracker.finishedCommand(commandID) {
        return result(finished, maximumOutputBytes: maximumOutputBytes)
      }
      guard let running = tracker.running, running.id == commandID else {
        throw AsterControlError(code: .notFound, message: "找不到命令 \(commandID)")
      }
      if running.needsInputEpisode > sinceEpisode || ContinuousClock.now >= deadline {
        return snapshot(running, maximumOutputBytes: maximumOutputBytes)
      }
      try await Task.sleep(for: timing.poll)
    }
  }

  /// 当前等输入轮次；`host.wait` 用它作为起点。
  func needsInputEpisode(of commandID: String) -> Int {
    tracker.running?.id == commandID ? tracker.running?.needsInputEpisode ?? 0 : 0
  }

  /// 向运行中的命令发 Ctrl-C，等宽限期内的结局。
  func interrupt(maximumOutputBytes: Int) async throws -> HostExecResult {
    guard let running = tracker.running else {
      throw AsterControlError(code: .notFound, message: "该终端没有运行中的命令")
    }
    try ensureVerifiedNativeSSH()
    guard surface.send("\u{03}") else {
      throw AsterControlError(code: .writeRejected, message: "终端当前不接受输入（只读或本地导航模式）")
    }
    tracker.requestInterrupt(at: now())
    let deadline = ContinuousClock.now + .milliseconds(Int(timing.interruptGrace * 1_000) + 1_000)
    return try await wait(
      commandID: running.id, deadline: deadline, maximumOutputBytes: maximumOutputBytes,
      sinceEpisode: Int.max)
  }

  /// 面板上的「中断」按钮：不管是不是 agent 的命令都发 Ctrl-C（用户可能在跑自己的程序）；
  /// agent 命令在跑时同时进入中断宽限期，之后记为 `interrupted` 并在下一条命令前重新同步。
  func userInterrupt() {
    guard surface.send("\u{03}") else { return }
    if tracker.running != nil {
      tracker.requestInterrupt(at: now())
    } else {
      needsResync = true
    }
  }

  /// 活动屏幕最后 `lines` 行。
  func read(lines: Int) -> String {
    lastActivity = now()
    let text = surface.readActiveScreen() ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
  }

  /// 关闭：结束进程，运行中的命令记 `ended`。
  func close() {
    guard state != .ended else { return }
    let scrollback = surface.readScrollback(maximumLines: timing.scrollbackLines)
    surface.terminate()
    monitorTask?.cancel()
    monitorTask = nil
    if let result = tracker.end(at: now(), scrollback: scrollback) { onCommandFinished?(result) }
    state = .ended
    onEnded?()
  }

  // MARK: - 结果投影

  /// 已完成命令 → 协议结果（按调用方预算再截断一次）。
  func result(_ finished: AgentHostCommandTracker.Finished, maximumOutputBytes: Int) -> HostExecResult {
    let output = AgentHostCommandFraming.truncate(finished.output, maximumBytes: maximumOutputBytes)
    return HostExecResult(
      commandID: finished.id, terminalID: terminalID, hostID: hostID.uuidString, hostName: hostName,
      status: finished.status, exitCode: finished.exitCode, output: output.text,
      outputTruncated: finished.outputTruncated || output.truncated, durationMs: finished.durationMs)
  }

  /// 运行中命令 → `running` / `needs_input` 快照，输出取回滚里开始标记之后的部分。
  private func snapshot(_ running: AgentHostCommandTracker.Running, maximumOutputBytes: Int) -> HostExecResult {
    let partial = tracker.partialOutput(surface.readScrollback(maximumLines: timing.scrollbackLines))
    let output = AgentHostCommandFraming.truncate(partial, maximumBytes: maximumOutputBytes)
    return HostExecResult(
      commandID: running.id, terminalID: terminalID, hostID: hostID.uuidString, hostName: hostName,
      status: running.prompt == nil ? .running : .needsInput, output: output.text,
      outputTruncated: output.truncated, prompt: running.prompt,
      durationMs: max(Int(now().timeIntervalSince(running.startedAt) * 1_000), 0))
  }
}
