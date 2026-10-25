// 菜单交互测试注入对话框与Git runner，不打开窗口、不执行真实push。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

actor PaneGitMenuRecorder {
  private var calls: [[String]] = []
  var failFetch = false
  func run(_ arguments: [String]) throws -> PaneGitService.Output {
    calls.append(arguments)
    switch arguments.first {
    case "branch": return .init(stdout: "main\n")
    case "for-each-ref": return .init(stdout: "main\ntopic\n")
    case "status": return .init(stdout: "M  tracked.txt\0")
    case "remote": return .init(stdout: "origin\tgit@github.com:example/project.git (fetch)\n")
    case "diff": return .init(stdout: "tracked.txt | 1 +\n")
    case "fetch" where failFetch: throw PaneGitService.Failure.commandFailed(1, "fixture fetch failed")
    default: return .init(stdout: "done")
    }
  }
  func reset(failing: Bool = false) { calls = []; failFetch = failing }
  func recorded() -> [[String]] { calls }
}

@MainActor
private func paneGitMenuDialogs() -> PaneGitMenu.Dialogs {
  var dialogs = PaneGitMenu.Dialogs()
  dialogs.prompt = { _, _ in nil }
  dialogs.progress = { _, _, _ in {} }
  dialogs.failure = { _, _ in }
  return dialogs
}

@MainActor
private func invokePaneGit(_ menu: NSMenu, title: String) throws {
  let item = try #require(menu.item(withTitle: title))
  _ = item.target?.perform(item.action, with: item)
}

@Test("Pane Git 按恢复顺序构造真实动作、分支和安全远程链接")
@MainActor
func paneGitMenuBuildsRepositoryActions() async throws {
  let recorder = PaneGitMenuRecorder()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  var opened: URL?
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service,
    openURL: { opened = $0; return true }, dialogs: paneGitMenuDialogs())
  let menu = try await controller.load()
  #expect(menu.items.map(\.title) == [L("\("main") · \("1") 项改动"), L("提交…"), L("创建分支…"), "", L("Push"), L("Pull"), L("Fetch"), "",
    L("合并…"), L("变基…"), "", L("切换到"), "main", "topic", "", "origin · github.com"])
  #expect(menu.item(withTitle: "main")?.isEnabled == false)
  try invokePaneGit(menu, title: "origin · github.com")
  #expect(opened?.absoluteString == "https://github.com/example/project")
}

@Test("Pane Git Push和Pull必须经用户确认，取消不调用变更命令", arguments: ["Push", "Pull"])
@MainActor
func paneGitMenuRequiresRemoteConfirmation(title: String) async throws {
  let recorder = PaneGitMenuRecorder()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  var prompts: [PaneGitMenu.Prompt] = []
  var dismissals = 0
  var dialogs = paneGitMenuDialogs()
  dialogs.prompt = { prompt, _ in prompts.append(prompt); return nil }
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service,
    onDismiss: { dismissals += 1 }, dialogs: dialogs)
  let menu = try await controller.load()
  await recorder.reset()
  try invokePaneGit(menu, title: title)
  await controller.task?.value
  #expect(prompts.first?.title == (title == "Push" ? L("推送到远程") : L("从远程拉取")))
  #expect(prompts.first?.accept == title)
  if title == "Push" { #expect(prompts.first?.message == L("将“\("main")”推送到远程仓库？")) }
  #expect(!(await recorder.recorded()).contains([title.lowercased()]))
  #expect(dismissals == 1)
}

@Test("Pane Git Fetch立即后台执行且进度正常关闭，失败可见", arguments: [false, true])
@MainActor
func paneGitMenuFetchReportsProgressAndFailure(failure: Bool) async throws {
  let recorder = PaneGitMenuRecorder()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  var titles: [String] = []
  var closed = 0
  var errors: [String] = []
  var completions = 0
  var dialogs = paneGitMenuDialogs()
  dialogs.prompt = { _, _ in Issue.record("Fetch不应弹确认"); return nil }
  dialogs.progress = { title, _, _ in titles.append(title); return { closed += 1 } }
  dialogs.failure = { error, _ in errors.append(error.localizedDescription) }
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service,
    onResult: { _ in completions += 1 }, dialogs: dialogs)
  let menu = try await controller.load()
  await recorder.reset(failing: failure)
  try invokePaneGit(menu, title: L("Fetch"))
  await controller.task?.value
  #expect(await recorder.recorded() == [["fetch"]])
  #expect(titles == [L("正在获取…")])
  #expect(closed == 1)
  #expect(completions == 1)
  #expect(errors.count == (failure ? 1 : 0))
  if failure { #expect(errors.first?.contains("fixture fetch failed") == true) }
}

@Test("Pane Git 对话框结果进入对应argv，Switch使用选中的本地分支", arguments: [
  "Create Branch…", "Commit…", "Merge…", "Rebase…", "topic",
])
@MainActor
func paneGitMenuExecutesSelectedAction(title: String) async throws {
  let recorder = PaneGitMenuRecorder()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  var dialogs = paneGitMenuDialogs()
  dialogs.prompt = { _, _ in title == "Commit…" ? "literal ; message" : "topic" }
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service, dialogs: dialogs)
  let menu = try await controller.load()
  await recorder.reset()
  let localizedTitle = switch title {
  case "Create Branch…": L("创建分支…")
  case "Commit…": L("提交…")
  case "Merge…": L("合并…")
  case "Rebase…": L("变基…")
  default: title
  }
  try invokePaneGit(menu, title: localizedTitle)
  await controller.task?.value
  let expected: [String]
  switch title {
  case "Create Branch…": expected = ["checkout", "-b", "topic"]
  case "Commit…": expected = ["commit", "-m", "literal ; message"]
  case "Merge…": expected = ["merge", "topic"]
  case "Rebase…": expected = ["rebase", "topic"]
  default: expected = ["checkout", "topic", "--"]
  }
  #expect((await recorder.recorded()).contains(expected))
}

@Test("Pane Git 拒绝菜单加载后已失效的Pane目标")
@MainActor
func paneGitMenuRejectsStalePaneTarget() async throws {
  let recorder = PaneGitMenuRecorder()
  let service = PaneGitService(runner: { _, arguments, _ in try await recorder.run(arguments) })
  var targetValid = true
  var dismissed = false
  var openedRemote = false
  let controller = PaneGitMenu(directory: "/fixture", isRemote: false, service: service,
    beforeAction: { targetValid }, onDismiss: { dismissed = true },
    openURL: { _ in openedRemote = true; return true }, dialogs: paneGitMenuDialogs())
  let menu = try await controller.load()
  await recorder.reset()
  targetValid = false
  try invokePaneGit(menu, title: L("Fetch"))
  try invokePaneGit(menu, title: "origin · github.com")
  await controller.task?.value
  #expect(await recorder.recorded().isEmpty)
  #expect(!dismissed)
  #expect(!openedRemote)
}
