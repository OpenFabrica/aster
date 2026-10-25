// 用可控异步边界验证Pane销毁、确认结束和取消；不显示窗口或执行真实Git操作。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
private final class PaneGitLifecycleGate {
  private var operation: String?
  private var pending: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  func pause(_ operation: String) { self.operation = operation }
  func waitIfPaused(_ arguments: [String]) async {
    guard arguments.first == operation, operation != nil else { return }
    operation = nil
    await withCheckedContinuation { continuation in
      pending = continuation
      observers.forEach { $0.resume() }
      observers.removeAll()
    }
  }
  func started() async {
    if pending != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func resume() { pending?.resume(); pending = nil }
}

@MainActor
private func lifecycleDialogs() -> PaneGitMenu.Dialogs {
  var dialogs = PaneGitMenu.Dialogs()
  dialogs.prompt = { _, _ in "" }
  dialogs.progress = { _, _, _ in {} }
  dialogs.failure = { error, _ in Issue.record("取消或失效目标不应呈现错误：\(error)") }
  return dialogs
}

@MainActor
private func beginLifecycleAction(_ menu: NSMenu, _ title: String) throws {
  let item = try #require(menu.item(withTitle: title))
  _ = item.target?.perform(item.action, with: item)
}

@Test("Pane Git 在准备返回、确认返回及执行前重新检查目标，导航只关闭一次", arguments: [
  "preparation", "confirmation", "progress",
])
@MainActor
func paneGitLifecycleRevalidatesAsyncBoundaries(boundary: String) async throws {
  let recorder = PaneGitMenuRecorder()
  let gate = PaneGitLifecycleGate()
  let service = PaneGitService(runner: { _, arguments, _ in
    await gate.waitIfPaused(arguments)
    return try await recorder.run(arguments)
  })
  var valid = true
  var dismissed = 0
  var prompted = 0
  var completed = 0
  var dialogs = lifecycleDialogs()
  dialogs.prompt = { _, _ in
    prompted += 1
    if boundary == "confirmation" { valid = false }
    return ""
  }
  dialogs.progress = { _, _, _ in
    if boundary == "progress" { valid = false }
    return {}
  }
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service,
    beforeAction: { valid }, onDismiss: { dismissed += 1 }, onResult: { _ in completed += 1 }, dialogs: dialogs)
  let menu = try await controller.load()
  await recorder.reset()
  if boundary == "preparation" { gate.pause("rev-parse") }
  let title = boundary == "preparation" ? L("Push") : boundary == "confirmation" ? L("Pull") : L("Fetch")
  try beginLifecycleAction(menu, title)
  let pending = try #require(controller.task)
  if boundary == "preparation" {
    await gate.started()
    valid = false
    gate.resume()
  }
  await pending.value
  #expect(!(await recorder.recorded()).contains { ["push", "pull", "fetch"].contains($0.first ?? "") })
  #expect(prompted == (boundary == "confirmation" ? 1 : 0))
  #expect(dismissed == 1)
  #expect(completed == 0)
}

@Test("Pane Git 取消立即清除进度且迟到查询不会重复关闭或通知成功")
@MainActor
func paneGitLifecycleCancellationClosesProgressOnce() async throws {
  let recorder = PaneGitMenuRecorder()
  let gate = PaneGitLifecycleGate()
  let service = PaneGitService(runner: { _, arguments, _ in
    await gate.waitIfPaused(arguments)
    return try await recorder.run(arguments)
  })
  var closes = 0
  var completed = 0
  var dialogs = lifecycleDialogs()
  dialogs.progress = { _, _, _ in { closes += 1 } }
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service,
    onResult: { _ in completed += 1 }, dialogs: dialogs)
  let menu = try await controller.load()
  gate.pause("fetch")
  try beginLifecycleAction(menu, L("Fetch"))
  let pending = try #require(controller.task)
  await gate.started()
  controller.cancel()
  #expect(closes == 1)
  gate.resume()
  await pending.value
  #expect(closes == 1)
  #expect(completed == 0)
}

@Test("Pane Git 取消结束待确认输入，注入对话框仍允许nil owner")
@MainActor
func paneGitLifecycleCancellationEndsPrompt() async throws {
  let recorder = PaneGitMenuRecorder()
  let gate = PaneGitLifecycleGate()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  var cancelled = 0
  var dialogs = lifecycleDialogs()
  dialogs.prompt = { _, owner in
    #expect(owner == nil)
    await gate.waitIfPaused(["prompt"])
    return ""
  }
  dialogs.cancelPrompt = { cancelled += 1; gate.resume() }
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service, dialogs: dialogs)
  let menu = try await controller.load()
  await recorder.reset()
  gate.pause("prompt")
  try beginLifecycleAction(menu, L("Pull"))
  let pending = try #require(controller.task)
  await gate.started()
  controller.cancel()
  await pending.value
  #expect(cancelled == 1)
  #expect(await recorder.recorded().isEmpty)
}

@Test("Pane Git 生产对话框缺少owner时退出Push和Pull，不退回应用级modal", arguments: ["Push", "Pull"])
@MainActor
func paneGitLifecycleLiveDialogsRequireOwner(title: String) async throws {
  let recorder = PaneGitMenuRecorder()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service)
  let menu = try await controller.load()
  await recorder.reset()
  try beginLifecycleAction(menu, title)
  await controller.task?.value
  #expect(await recorder.recorded().isEmpty)
}
