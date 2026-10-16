// 批准面板排队：不同命令各自一个请求、一次只显示一个面板，「允许一次」只放行一个等待方，
// 全局挂起上限，撤掉请求后显示下一个。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Suite("agent 主机批准排队")
@MainActor
struct AgentHostApprovalQueueTests {
  private let hostID = UUID()

  /// 造一条批准请求。
  private func request(session: String = "s1", command: String = "ls") -> AgentHostApprovalRequest {
    AgentHostApprovalRequest(
      caller: AgentHostResolvedCaller(key: session, session: session), hostID: hostID, hostName: "prod",
      target: "u@h:22", reason: nil, command: command, targetFingerprint: "f")
  }

  /// 记录面板的协调者；返回协调者与面板列表盒子。
  private func makeCoordinator() -> (AgentHostApprovalCoordinator, PanelLog) {
    let log = PanelLog()
    let coordinator = AgentHostApprovalCoordinator(makePanel: { request, answer in
      let panel = FakeApprovalPanel(answer: answer)
      log.panels.append((request, panel))
      return panel
    }, alert: { _ in })
    return (coordinator, log)
  }

  @MainActor
  final class PanelLog {
    var panels: [(request: AgentHostApprovalRequest, panel: FakeApprovalPanel)] = []
  }

  @Test("不同命令不合并：排队一次只显示一个面板，回答只作用于显示的那条")
  func distinctCommandsQueue() async throws {
    let (coordinator, log) = makeCoordinator()
    var answered: [String?] = []
    coordinator.onAnswer = { request, _, _ in answered.append(request.command) }
    let first = Task { try await coordinator.requestApproval(request(command: "uptime"), timeout: .seconds(5)) }
    await pollUntil { coordinator.pendingRequestCount == 1 }
    let second = Task { try await coordinator.requestApproval(request(command: "rm -rf /"), timeout: .seconds(5)) }
    await pollUntil { coordinator.pendingRequestCount == 2 }
    #expect(log.panels.map(\.request.command) == ["uptime"])
    #expect(coordinator.pendingRequestCount == 2)
    log.panels[0].panel.answer(.allowSession)
    #expect(try await first.value == .allowSession)
    try #require(log.panels.count == 2)
    // 第二条在第一条回答后才出现，内容就是它自己。
    #expect(log.panels.map(\.request.command) == ["uptime", "rm -rf /"])
    log.panels[1].panel.answer(.deny)
    #expect(try await second.value == .deny)
    #expect(answered == ["uptime", "rm -rf /"])
  }

  @Test("相同命令合并后「允许一次」只放行最早的等待方，其余重新出面板")
  func allowOnceReleasesOneWaiter() async throws {
    let (coordinator, log) = makeCoordinator()
    let first = Task { try await coordinator.requestApproval(request(), timeout: .seconds(5)) }
    await pollUntil { log.panels.count == 1 }
    let second = Task { try await coordinator.requestApproval(request(), timeout: .seconds(5)) }
    await pollUntil { log.panels.first?.panel.pendingCount == 2 }
    try #require(log.panels.count == 1)
    #expect(log.panels[0].panel.pendingCount == 2)
    log.panels[0].panel.answer(.allowOnce)
    #expect(try await first.value == .allowOnce)
    try #require(log.panels.count == 2)
    #expect(log.panels[0].panel.closed)
    log.panels[1].panel.answer(.deny)
    #expect(try await second.value == .deny)
  }

  @Test("全局最多挂起 4 个不同请求，第 5 个 limit_exceeded；相同请求仍可合并")
  func globalLimit() async throws {
    let (coordinator, _) = makeCoordinator()
    var tasks: [Task<AgentHostApprovalAnswer?, any Error>] = []
    for index in 0..<AgentHostApprovalCoordinator.maximumPendingRequests {
      let pending = request(session: "s\(index)", command: "c\(index)")
      tasks.append(Task { try await coordinator.requestApproval(pending, timeout: .seconds(5)) })
    }
    await pollUntil { coordinator.pendingRequestCount == AgentHostApprovalCoordinator.maximumPendingRequests }
    await #expect(throws: AsterControlError.self) {
      try await coordinator.requestApproval(request(session: "extra", command: "x"), timeout: .milliseconds(10))
    }
    #expect(try await coordinator.requestApproval(request(session: "s0", command: "c0"), timeout: .milliseconds(10)) == nil)
    coordinator.dismissAll(hostID: nil)
    for task in tasks { #expect(try await task.value == nil) }
  }

  @Test("撤掉显示中的请求后，下一个排队的请求出面板")
  func dismissPresentsNext() async throws {
    let (coordinator, log) = makeCoordinator()
    let otherHost = AgentHostApprovalRequest(
      caller: AgentHostResolvedCaller(key: "s1", session: "s1"), hostID: UUID(), hostName: "other",
      target: "u@o:22", reason: nil, command: "ls", targetFingerprint: "g")
    let first = Task { try await coordinator.requestApproval(request(), timeout: .seconds(5)) }
    await pollUntil { coordinator.pendingRequestCount == 1 }
    let second = Task { try await coordinator.requestApproval(otherHost, timeout: .seconds(5)) }
    await pollUntil { coordinator.pendingRequestCount == 2 }
    coordinator.dismissAll(hostID: hostID)
    #expect(try await first.value == nil)
    try #require(log.panels.map(\.request.hostName) == ["prod", "other"])
    log.panels[1].panel.answer(.allowOnce)
    #expect(try await second.value == .allowOnce)
  }

  @Test("批准面板：出现或内容变化时批准按钮先禁用约 1 秒")
  func panelArmsApproveButtons() async throws {
    let panel = AgentHostApprovalPanel(request: request(), onAnswer: { _ in })
    defer { panel.close() }
    #expect(!panel.approveButtonsEnabled)
    try await Task.sleep(for: AgentHostApprovalPanel.approvalArmDelay / 2)
    #expect(!panel.approveButtonsEnabled)
    await pollUntil { panel.approveButtonsEnabled }
    #expect(panel.approveButtonsEnabled)
    panel.update(request(), pendingCount: 2)
    #expect(!panel.approveButtonsEnabled)
  }
}
