// Send to 的项目分组、菜单选择与新建目标预填行为。
import AppKit
import AsterCore
import Testing
@testable import Aster

@Test("聊天目标按仓库与类型分组、排序，空组省略且新建目录保持参考顺序")
@MainActor
func agentChatTargetsGroupByProjectAndRetainSelection() throws {
  func destination(_ title: String, _ provider: AgentProvider?, _ directory: String) -> AgentChatDestination {
    .init(tabID: UUID(), paneID: UUID(), provider: provider, title: title, workingDirectory: directory)
  }
  let alpha = destination("alpha", .codex, "/repo/src")
  let beta = destination("Beta", .claudeCode, "/repo")
  let shell = destination("shell", nil, "/repo/tests")
  let other = destination("Other", nil, "/elsewhere")
  let presentation = AgentChatPresentation(originPaneID: UUID(), destinations: [beta, other, shell, alpha],
    selection: nil, transcript: "", transcriptHasError: false, workingDirectory: "/repo/docs")
  let popup = NSPopUpButton()
  let roots = ["/repo/docs": "/repo", "/repo/src": "/repo", "/repo/tests": "/repo"]
  AgentChatTargetsMenu.populate(popup, presentation: presentation, projectPaths: roots)
  let items = try #require(popup.menu).items
  let headers = items.filter { !$0.isSeparatorItem && $0.representedObject == nil }.map(\.title)
  #expect(headers == [L("当前项目的 Agents"), L("当前项目的终端"), L("其他终端"), L("创建新会话")])
  let existing = items.compactMap { item -> AgentChatDestination? in
    guard case .existing(let destination) = item.representedObject as? AgentChatTargetChoice else { return nil }
    return destination
  }
  #expect(existing == [alpha, beta, shell, other])
  let alphaItem = try #require(items.first { ($0.representedObject as? AgentChatTargetChoice) == .existing(alpha) })
  #expect(alphaItem.attributedTitle?.string == "alpha  Codex")
  let codex = try #require(items.first { ($0.representedObject as? AgentChatTargetChoice) == .create(.codex) })
  popup.select(codex)
  AgentChatTargetsMenu.populate(popup, presentation: presentation, projectPaths: roots)
  #expect((popup.selectedItem?.representedObject as? AgentChatTargetChoice) == .create(.codex))
  #expect(AgentChatNewTarget.allCases.map(\.command) == ["claude", "codex", "opencode", "cursor-agent", "kimi", "pi", "omp", "grok", "reasonix", "codebuddy", "agy", "copilot"])
  popup.select(popup.itemArray.first { ($0.representedObject as? AgentChatTargetChoice) == .existing(alpha) })
  var changed = presentation
  let renamed = AgentChatDestination(tabID: alpha.tabID, paneID: alpha.paneID, provider: .codex,
    title: "Renamed", workingDirectory: "/repo/src")
  changed.destinations = [renamed, beta]
  AgentChatTargetsMenu.populate(popup, presentation: changed, projectPaths: roots)
  #expect((popup.selectedItem?.representedObject as? AgentChatTargetChoice) == .existing(renamed))
}

@Test("没有已有目标时仍可选择新建 Agent，选择菜单不会创建终端")
@MainActor
func agentChatTargetsOfferCreationWithoutRunningTerminals() {
  let popup = NSPopUpButton()
  let presentation = AgentChatPresentation(originPaneID: UUID(), destinations: [], selection: nil,
    transcript: "", transcriptHasError: false)
  AgentChatTargetsMenu.populate(popup, presentation: presentation)
  #expect(popup.numberOfItems == 13)
  #expect((popup.selectedItem?.representedObject as? AgentChatTargetChoice) == .create(.claudeCode))
  #expect(AgentChatNewTarget.cursorCLI.launchComponents(overrides: [:]) == ["cursor-agent"])
  #expect(AgentChatNewTarget.codex.launchComponents(overrides: ["codex": ["/tmp/custom cli", "--flag"]]) == ["/tmp/custom cli", "--flag"])
}

@Test("新建聊天目标先校验消息，非法消息不会创建终端")
@MainActor
func newAgentChatValidatesBeforeCreatingTerminal() async {
  let model = AppModel(defaults: UserDefaults(suiteName: "ChatCreation.\(UUID().uuidString)")!)
  #expect(await model.prefillNewAgentChat(.codex, workingDirectory: "/tmp", comment: String(repeating: "x", count: 9000),
    selection: nil, transcript: nil, fileContext: nil) == false)
  #expect(model.tabs.isEmpty)
}

@Test("新建聊天目标在 CLI 运行后预填上下文，不提交消息")
@MainActor
func newAgentChatPrefillsRunningCLIWithoutReturn() async throws {
  let defaults = UserDefaults(suiteName: "ChatCreation.\(UUID().uuidString)")!
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  // 使用本机 cat 充当不访问网络的交互 CLI，验证真实 PTY；不启动外部 Agent。
  model.agentLaunchCommands["reasonix"] = ["/bin/cat"]
  let sending = Task { await model.prefillNewAgentChat(.reasonix, workingDirectory: "/tmp", comment: "CHAT_NEW_TARGET",
    selection: nil, transcript: nil, fileContext: "Path: /tmp/sample.swift") }
  defer { sending.cancel(); model.tabs.forEach { $0.stop(immediately: true) } }
  for _ in 0..<20 where model.selectedTab == nil { await Task.yield() }
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let terminal = try liveGhosttyView(for: session, preferences: preferences)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = terminal.superview
  window.orderFront(nil)
  defer { window.orderOut(nil) }
  for _ in 0..<250 {
    if session.shellIntegrationDetected { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(session.shellIntegrationDetected)
  model.startPendingRecipeCommands(paneID: tab.activePaneID)
  for _ in 0..<100 {
    if session.hasForegroundCommand { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(session.hasForegroundCommand)
  var writes: [UInt8] = []
  observeTestPTYWrites(terminal) { writes += $0 }
  #expect(await sending.value)
  try await Task.sleep(for: .milliseconds(50))
  let text = String(decoding: writes, as: UTF8.self)
  #expect(text.contains("CHAT_NEW_TARGET"))
  #expect(text.contains("sample.swift"))
  // cat 不协商 bracketed paste，多行正文中的换行会编码成 CR；末尾不能追加提交键。
  #expect(writes.last != 13)
  #expect(tab.workingDirectory == "/tmp")
}

@Test("新建 CLI 失败时不向 Shell 写入上下文，保留可重试错误")
@MainActor
func newAgentChatFailureDoesNotPasteMessageIntoShell() async throws {
  let defaults = UserDefaults(suiteName: "ChatFailure.\(UUID().uuidString)")!
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.agentLaunchCommands["reasonix"] = ["/does-not-exist/aster-chat-agent"]
  let sending = Task { await model.prefillNewAgentChat(.reasonix, workingDirectory: "/tmp",
    comment: "SHOULD_NOT_REACH_SHELL", selection: nil, transcript: nil, fileContext: nil) }
  defer { sending.cancel(); model.tabs.forEach { $0.stop(immediately: true) } }
  for _ in 0..<20 where model.selectedTab == nil { await Task.yield() }
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let terminal = try liveGhosttyView(for: session, preferences: preferences)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = terminal.superview
  window.orderFront(nil)
  defer { window.orderOut(nil) }
  for _ in 0..<250 {
    if session.shellIntegrationDetected { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(session.shellIntegrationDetected)
  var writes: [UInt8] = []
  observeTestPTYWrites(terminal) { writes += $0 }
  model.startPendingRecipeCommands(paneID: tab.activePaneID)
  #expect(await sending.value == false)
  #expect(!String(decoding: writes, as: UTF8.self).contains("SHOULD_NOT_REACH_SHELL"))
  #expect(model.notice?.contains("Reasonix") == true)
  // 保留的对话框重新展开菜单时能发现刚创建的终端，不必丢失来源和 Comment。
  let presentation = AgentChatPresentation(originPaneID: UUID(), destinations: [], selection: nil,
    transcript: "", transcriptHasError: false, fileContext: .init(path: "/tmp/source.txt", selection: nil, lines: nil))
  let sheet = AgentChatSendSheetController(model: model, presentation: presentation)
  sheet.present(on: window) {}
  let content = try #require(window.attachedSheet?.contentView)
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  let popup = try #require(descendants(content).compactMap { $0 as? NSPopUpButton }.first)
  NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: popup)
  #expect(popup.itemArray.contains {
    guard case .existing(let destination) = $0.representedObject as? AgentChatTargetChoice else { return false }
    return destination.paneID == tab.activePaneID
  })
  if let attached = window.attachedSheet { window.endSheet(attached) }
}
