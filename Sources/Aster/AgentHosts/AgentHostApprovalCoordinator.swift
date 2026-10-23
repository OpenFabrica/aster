// agent 主机访问的批准流程：非模态面板 + 有期限的异步等待。
// 绝不 runModal / sheet：控制连接上的请求各自挂起等待，主线程照常处理输入与其它请求。
// 只合并内容完全相同的请求（同一会话、主机、目标与命令）；不同请求排队，一次只显示一个面板，
// 用户看到的永远就是要批准的那一条。等待方超时后面板仍保留，迟到的回答照样生效。
import AppKit
import AsterCore

/// 调用方身份（已并入 provider 与 agent session ID 的有效会话键）。
struct AgentHostResolvedCaller: Hashable, Sendable {
  /// 授权与终端复用的键。
  var key: String
  var session: String
  var client: String?
  var pane: String?
  var provider: AgentProvider?
  var agentSessionID: String?
  /// 调用方 Pane 的 UUID：终端默认停靠在这个 Pane 底部。只用于呈现，不进会话键、不进审计。
  var paneUUID: UUID?

  /// 面板与标题里的 agent 名：provider 显示名，其次客户端名。
  var displayName: String {
    if let provider { return provider.displayName }
    if let client, !client.isEmpty { return client }
    return "Agent"
  }

  /// 审计里的操作者。
  var auditActor: AgentHostAuditRecord.Actor {
    .agent(session: key, client: client, pane: pane, provider: provider?.rawValue, agentSessionID: agentSessionID)
  }
}

/// 一次批准请求的展示内容。命令原样显示（不脱敏）：用户要看清楚到底会执行什么。
/// 整个值就是合并键：只有各字段完全相同的请求才共用一个面板。
struct AgentHostApprovalRequest: Hashable, Sendable {
  var caller: AgentHostResolvedCaller
  var hostID: UUID
  var hostName: String
  var target: String
  var reason: String?
  /// nil 表示 `host.open`（只连接，不执行命令）。
  var command: String?
  /// 发起时的连接目标指纹。批准落成的授权绑定它，而不是回答时重新解析的目标：
  /// 面板挂着期间主机地址被改，用户批准的仍是面板上显示的那个目标。
  var targetFingerprint: String
}

/// 用户的回答。
enum AgentHostApprovalAnswer: Equatable, Sendable {
  case deny
  case allowOnce
  case allowSession
  case allowAlways
}

/// 批准入口；测试注入替身。
@MainActor
protocol AgentHostApprovalPresenting: AnyObject {
  /// 等用户回答；`timeout` 到达返回 nil，面板继续保留。
  /// 挂起的不同请求已达上限时抛 `limit_exceeded`。
  func requestApproval(_ request: AgentHostApprovalRequest, timeout: Duration) async throws -> AgentHostApprovalAnswer?
  /// 每次用户回答时调用一次：`hadLiveWaiters == false` 表示所有等待方都已超时返回。
  var onAnswer: ((AgentHostApprovalRequest, AgentHostApprovalAnswer, _ hadLiveWaiters: Bool) -> Void)? { get set }
  /// 撤掉满足条件的挂起请求（主机被删除或目标变化、开关关闭、App 退出），等待方拿到 nil。
  func dismiss(where shouldDismiss: (AgentHostApprovalRequest) -> Bool)
}

extension AgentHostApprovalPresenting {
  /// 撤掉某台主机（nil 为全部）的挂起请求。
  func dismissAll(hostID: UUID?) {
    dismiss { hostID == nil || $0.hostID == hostID }
  }
}

/// 面板句柄：协调者只需要更新与关闭。
@MainActor
protocol AgentHostApprovalPanelHandling: AnyObject {
  func update(_ request: AgentHostApprovalRequest, pendingCount: Int)
  func close()
}

/// 生产实现。
@MainActor
final class AgentHostApprovalCoordinator: AgentHostApprovalPresenting {
  /// 新建面板；参数是请求与回答回调。测试替换成不弹窗的替身。
  typealias PanelFactory = @MainActor (
    AgentHostApprovalRequest, @escaping @MainActor (AgentHostApprovalAnswer) -> Void
  ) -> any AgentHostApprovalPanelHandling

  /// 全局最多挂起的不同请求数：防止 agent 换着命令或会话名刷出一排面板。
  static let maximumPendingRequests = 4

  private struct Waiter {
    var id: UUID
    var continuation: CheckedContinuation<AgentHostApprovalAnswer?, Never>
  }

  private struct Prompt {
    /// 面板还在排队时为 nil。
    var panel: (any AgentHostApprovalPanelHandling)?
    /// 按到达顺序排列：「允许一次」只放行最早的一个。
    var waiters: [Waiter] = []
    var requestCount = 1
  }

  private var prompts: [AgentHostApprovalRequest: Prompt] = [:]
  /// 排队顺序；只有队首显示面板。
  private var order: [AgentHostApprovalRequest] = []
  private let makePanel: PanelFactory
  /// 面板出现时的提醒（通知 + 请求注意）；测试置空。
  var alert: @MainActor (AgentHostApprovalRequest) -> Void
  var onAnswer: ((AgentHostApprovalRequest, AgentHostApprovalAnswer, Bool) -> Void)?

  init(
    makePanel: @escaping PanelFactory = { request, answer in AgentHostApprovalPanel(request: request, onAnswer: answer) },
    alert: @escaping @MainActor (AgentHostApprovalRequest) -> Void = AgentHostApprovalCoordinator.defaultAlert
  ) {
    self.makePanel = makePanel
    self.alert = alert
  }

  /// 登记请求（相同请求合并，不同请求排队）并有期限地等回答。
  func requestApproval(_ request: AgentHostApprovalRequest, timeout: Duration) async throws -> AgentHostApprovalAnswer? {
    if var prompt = prompts[request] {
      prompt.requestCount += 1
      prompts[request] = prompt
      prompt.panel?.update(request, pendingCount: prompt.requestCount)
    } else {
      guard prompts.count < Self.maximumPendingRequests else {
        throw AsterControlError(
          code: .limitExceeded, message: "已有 \(Self.maximumPendingRequests) 个批准请求在等用户回答，先等这些处理完")
      }
      prompts[request] = Prompt()
      order.append(request)
      presentNextIfIdle()
    }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<AgentHostApprovalAnswer?, Never>) in
        guard prompts[request] != nil else {
          continuation.resume(returning: nil)
          return
        }
        prompts[request]?.waiters.append(Waiter(id: waiterID, continuation: continuation))
        Task { @MainActor [weak self] in
          do { try await Task.sleep(for: timeout) } catch {}
          self?.expire(request, waiterID: waiterID)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.expire(request, waiterID: waiterID) }
    }
  }

  /// 挂起的不同请求数（含排队未显示的）。
  var pendingRequestCount: Int { prompts.count }

  /// 没有面板在显示时，把队首请求的面板弹出来。
  private func presentNextIfIdle() {
    guard !order.contains(where: { prompts[$0]?.panel != nil }), let next = order.first,
      let prompt = prompts[next]
    else { return }
    let panel = makePanel(next) { [weak self] answer in self?.answer(next, with: answer) }
    if prompt.requestCount > 1 { panel.update(next, pendingCount: prompt.requestCount) }
    prompts[next]?.panel = panel
    alert(next)
  }

  /// 等待方超时或被取消：只撤掉它自己，面板保留。
  private func expire(_ request: AgentHostApprovalRequest, waiterID: UUID) {
    guard let index = prompts[request]?.waiters.firstIndex(where: { $0.id == waiterID }),
      let waiter = prompts[request]?.waiters.remove(at: index)
    else { return }
    waiter.continuation.resume(returning: nil)
  }

  /// 用户回答：关面板，先让回答生效（授权 / 冷却），再唤醒等待方，然后显示下一个排队的请求。
  ///
  /// 「允许一次」只放行最早的一个等待方：其余相同请求留在队首重新出现，按钮重新延迟启用，
  /// 用户要为每一次执行单独点头。
  private func answer(_ request: AgentHostApprovalRequest, with answer: AgentHostApprovalAnswer) {
    guard var prompt = prompts[request] else { return }
    prompt.panel?.close()
    prompt.panel = nil
    if answer == .allowOnce, prompt.waiters.count > 1 {
      let first = prompt.waiters.removeFirst()
      prompt.requestCount = prompt.waiters.count
      prompts[request] = prompt
      onAnswer?(request, answer, true)
      first.continuation.resume(returning: answer)
      presentNextIfIdle()
      return
    }
    prompts.removeValue(forKey: request)
    order.removeAll { $0 == request }
    onAnswer?(request, answer, !prompt.waiters.isEmpty)
    for waiter in prompt.waiters { waiter.continuation.resume(returning: answer) }
    presentNextIfIdle()
  }

  /// 撤掉满足条件的请求：关面板、唤醒等待方（nil），再显示剩下队列的队首。
  func dismiss(where shouldDismiss: (AgentHostApprovalRequest) -> Bool) {
    let matching = order.filter(shouldDismiss)
    guard !matching.isEmpty else { return }
    for request in matching {
      guard let prompt = prompts.removeValue(forKey: request) else { continue }
      prompt.panel?.close()
      for waiter in prompt.waiters { waiter.continuation.resume(returning: nil) }
    }
    order.removeAll { prompts[$0] == nil }
    presentNextIfIdle()
  }

  /// 默认提醒：系统通知 + Dock 请求注意。通知里的命令先脱敏：通知中心会长期留存历史。
  static func defaultAlert(_ request: AgentHostApprovalRequest) {
    NSApp.requestUserAttention(.informationalRequest)
    TerminalNotificationService.shared.post(
      TerminalNotification(
        title: L("\(request.caller.displayName) 请求访问 \(request.hostName)"),
        body: request.command.map { AgentHostCommandRedactor.redact($0).text } ?? L("打开 SSH 终端"), urgency: .critical),
      category: .application, configuration: AsterConfiguration().shell, sourceTabIsFocused: false)
  }
}
