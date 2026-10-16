// agent 主机访问的批准流程：非模态面板 + 有期限的异步等待。
// 绝不 runModal / sheet：控制连接上的请求各自挂起等待，主线程照常处理输入与其它请求。
// 同一（会话、主机）的并发请求合并成一个面板；等待方超时后面板仍保留，迟到的回答照样生效。
import AppKit
import AsterCore

/// 调用方身份（已并入 provider 与 agent session ID 的有效会话键）。
struct AgentHostResolvedCaller: Equatable, Sendable {
  /// 授权与终端复用的键。
  var key: String
  var session: String
  var client: String?
  var pane: String?
  var provider: AgentProvider?
  var agentSessionID: String?

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
struct AgentHostApprovalRequest: Equatable, Sendable {
  var caller: AgentHostResolvedCaller
  var hostID: UUID
  var hostName: String
  var target: String
  var reason: String?
  /// nil 表示 `host.open`（只连接，不执行命令）。
  var command: String?
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
  func requestApproval(_ request: AgentHostApprovalRequest, timeout: Duration) async -> AgentHostApprovalAnswer?
  /// 每次用户回答时调用一次：`hadLiveWaiters == false` 表示所有等待方都已超时返回。
  var onAnswer: ((AgentHostApprovalRequest, AgentHostApprovalAnswer, _ hadLiveWaiters: Bool) -> Void)? { get set }
  /// 关掉某会话 / 主机上所有挂起的面板（主机被删除、App 退出）。
  func dismissAll(hostID: UUID?)
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

  private struct Prompt {
    var request: AgentHostApprovalRequest
    var panel: (any AgentHostApprovalPanelHandling)?
    var waiters: [UUID: CheckedContinuation<AgentHostApprovalAnswer?, Never>] = [:]
    var requestCount = 1
  }

  private var prompts: [String: Prompt] = [:]
  private let makePanel: PanelFactory
  /// 新面板出现时的提醒（通知 + 请求注意）；测试置空。
  var alert: @MainActor (AgentHostApprovalRequest) -> Void
  var onAnswer: ((AgentHostApprovalRequest, AgentHostApprovalAnswer, Bool) -> Void)?

  init(
    makePanel: @escaping PanelFactory = { request, answer in AgentHostApprovalPanel(request: request, onAnswer: answer) },
    alert: @escaping @MainActor (AgentHostApprovalRequest) -> Void = AgentHostApprovalCoordinator.defaultAlert
  ) {
    self.makePanel = makePanel
    self.alert = alert
  }

  /// 合并键：同一会话对同一主机只弹一个面板。
  private static func key(_ request: AgentHostApprovalRequest) -> String {
    "\(request.caller.key)|\(request.hostID.uuidString)"
  }

  func requestApproval(_ request: AgentHostApprovalRequest, timeout: Duration) async -> AgentHostApprovalAnswer? {
    let key = Self.key(request)
    if var prompt = prompts[key] {
      // 合并：面板显示最新一条命令，并注明还有几条在等。
      prompt.request = request
      prompt.requestCount += 1
      prompt.panel?.update(request, pendingCount: prompt.requestCount)
      prompts[key] = prompt
    } else {
      var prompt = Prompt(request: request)
      prompt.panel = makePanel(request) { [weak self] answer in self?.answer(key: key, with: answer) }
      prompts[key] = prompt
      alert(request)
    }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<AgentHostApprovalAnswer?, Never>) in
        guard prompts[key] != nil else {
          continuation.resume(returning: nil)
          return
        }
        prompts[key]?.waiters[waiterID] = continuation
        Task { @MainActor [weak self] in
          do { try await Task.sleep(for: timeout) } catch {}
          self?.expire(key: key, waiterID: waiterID)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.expire(key: key, waiterID: waiterID) }
    }
  }

  /// 等待方超时或被取消：只撤掉它自己，面板保留。
  private func expire(key: String, waiterID: UUID) {
    prompts[key]?.waiters.removeValue(forKey: waiterID)?.resume(returning: nil)
  }

  /// 用户回答：关面板，先让回答生效（授权 / 冷却），再唤醒所有仍在等的请求。
  private func answer(key: String, with answer: AgentHostApprovalAnswer) {
    guard let prompt = prompts.removeValue(forKey: key) else { return }
    prompt.panel?.close()
    onAnswer?(prompt.request, answer, !prompt.waiters.isEmpty)
    for continuation in prompt.waiters.values { continuation.resume(returning: answer) }
  }

  func dismissAll(hostID: UUID?) {
    for (key, prompt) in prompts where hostID == nil || prompt.request.hostID == hostID {
      prompts.removeValue(forKey: key)
      prompt.panel?.close()
      for continuation in prompt.waiters.values { continuation.resume(returning: nil) }
    }
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
