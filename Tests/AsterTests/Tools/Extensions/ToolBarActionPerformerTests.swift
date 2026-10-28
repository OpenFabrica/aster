// bar 项目 onClick 的门禁：剪贴板要 clipboard.write；终端要 terminal.insert，insert 永不回车，submit 拒绝控制字符；
// openURL 每次都确认；openPanel 只开同插件、可挂载的 panel；feature 只开同插件的功能。
import AppKit
import AsterCore
import Testing

@testable import Aster

/// 记录写入的假终端。
@MainActor
private final class FakeTerminalTarget: ToolBarTerminalTarget {
  private(set) var inserted: [String] = []
  private(set) var submitted: [String] = []

  func insert(_ text: String) -> String? {
    inserted.append(text)
    return nil
  }

  func submit(_ text: String) -> String? {
    submitted.append(text)
    return nil
  }
}

@MainActor
@Suite("界面扩展：bar 动作门禁")
struct ToolBarActionPerformerTests {
  /// 一套假服务与执行器，记录各出口被调了什么。
  @MainActor
  private final class Harness {
    let services = FakeToolBridgeServices()
    let terminal = FakeTerminalTarget()
    var entries: [ToolViewEntry] = []
    var features: [String: ToolCatalogEntry] = [:]
    private(set) var launched: [(String, String?)] = []
    private(set) var revealed: [String] = []
    private(set) var refreshed: [String] = []
    private(set) var notices: [String] = []
    var hasTerminal = true

    lazy var performer = ToolBarActionPerformer(
      services: services,
      terminal: { [unowned self] in self.hasTerminal ? self.terminal : nil },
      viewEntries: { [unowned self] in self.entries },
      featureEntry: { [unowned self] in self.features[$0] },
      launchFeature: { [unowned self] entry, text in self.launched.append((entry.id, text)) },
      revealPanel: { [unowned self] in self.revealed.append($0) },
      refresh: { [unowned self] in self.refreshed.append($0) },
      notify: { [unowned self] in self.notices.append($0) },
      window: { nil })
  }

  private func bar(_ permissions: Set<ToolPermission> = [], pluginID: String = "test.plugin") -> ToolViewEntry {
    makeToolViewEntry(pluginID: pluginID, permissions: permissions)
  }

  @Test("copy 需要 clipboard.write；有权限时按 concealed 写剪贴板")
  func copyRequiresClipboardWritePermission() async {
    let harness = Harness()
    let denied = await harness.performer.perform(.copy(text: "main", concealed: false), from: bar())
    guard case .rejected = denied else {
      Issue.record("没有权限却放行了")
      return
    }
    #expect(harness.services.clipboard == nil)
    #expect(harness.notices.count == 1)
    let allowed = await harness.performer.perform(.copy(text: "s3cret", concealed: true), from: bar([.clipboardWrite]))
    #expect(allowed == .performed)
    #expect(harness.services.clipboard == "s3cret")
    #expect(harness.services.clipboardConcealed)
  }

  @Test("terminal insert 需要 terminal.insert，只预填不回车；没有终端时提示")
  func terminalInsertNeverSubmits() async {
    let harness = Harness()
    let denied = await harness.performer.perform(.terminal(text: "git pull", mode: .insert), from: bar())
    #expect(denied != .performed)
    let allowed = await harness.performer.perform(
      .terminal(text: "git pull --ff-only", mode: .insert), from: bar([.terminalInsert]))
    #expect(allowed == .performed)
    #expect(harness.terminal.inserted == ["git pull --ff-only"])
    #expect(harness.terminal.submitted.isEmpty)
    harness.hasTerminal = false
    let noTerminal = await harness.performer.perform(.terminal(text: "ls", mode: .insert), from: bar([.terminalInsert]))
    guard case .rejected = noTerminal else {
      Issue.record("没有终端却报告成功")
      return
    }
  }

  @Test("terminal submit 含控制字符（换行、制表符、ESC）整条拒绝；正常命令写入并回车")
  func terminalSubmitRejectsControlCharacters() async {
    let harness = Harness()
    let entry = bar([.terminalInsert])
    for text in ["git push\nrm -rf ~", "ls\t", "echo \u{1B}[31m", "a\u{7F}"] {
      let outcome = await harness.performer.perform(.terminal(text: text, mode: .submit), from: entry)
      #expect(outcome == .rejected(ToolShellCommand.EncodingError.controlCharacters.localizedDescription))
    }
    #expect(harness.terminal.submitted.isEmpty)
    let ok = await harness.performer.perform(.terminal(text: "git push", mode: .submit), from: entry)
    #expect(ok == .performed)
    #expect(harness.terminal.submitted == ["git push"])
    #expect(harness.terminal.inserted.isEmpty)
  }

  @Test("openURL 每次都弹确认，同意才打开；只认 http(s)")
  func openURLAsksConfirmationEveryTime() async throws {
    let harness = Harness()
    let url = try #require(URL(string: "https://example.com/pr/1"))
    harness.services.confirmResult = false
    let declined = await harness.performer.perform(.openURL(url), from: bar())
    #expect(declined == .declined)
    #expect(harness.services.openedURLs.isEmpty)
    harness.services.confirmResult = true
    _ = await harness.performer.perform(.openURL(url), from: bar())
    _ = await harness.performer.perform(.openURL(url), from: bar())
    #expect(harness.services.confirmedURLs.count == 3)
    #expect(harness.services.openedURLs == [url, url])
    let file = URL(fileURLWithPath: "/etc/passwd")
    let rejected = await harness.performer.perform(.openURL(file), from: bar())
    #expect(rejected != .performed)
    #expect(harness.services.confirmedURLs.count == 3)
  }

  @Test("openPanel 只打开同插件、panel 类型且可挂载的视图")
  func openPanelOnlyForSamePluginPanelViews() async {
    let harness = Harness()
    let ownPanel = makeToolViewEntry(viewID: "status", kind: .panel, slot: .inspectorPanel)
    let otherPanel = makeToolViewEntry(pluginID: "other.plugin", viewID: "status", kind: .panel, slot: .inspectorPanel)
    let disabledPanel = makeToolViewEntry(viewID: "off", kind: .panel, slot: .inspectorPanel, isEnabled: false)
    let ownBar = makeToolViewEntry(viewID: "bar2")
    harness.entries = [otherPanel, ownPanel, disabledPanel, ownBar]
    #expect(await harness.performer.perform(.openPanel(viewID: "status"), from: bar()) == .performed)
    #expect(harness.revealed == [ownPanel.id])
    #expect(await harness.performer.perform(.openPanel(viewID: "off"), from: bar()) != .performed)
    #expect(await harness.performer.perform(.openPanel(viewID: "bar2"), from: bar()) != .performed)
    #expect(await harness.performer.perform(.openPanel(viewID: "status"), from: bar(pluginID: "third")) != .performed)
    #expect(harness.revealed == [ownPanel.id])
  }

  @Test("feature 只打开同插件目录里仍可用的功能；refresh 交给调度器")
  func featureOnlyForSamePlugin() async {
    let harness = Harness()
    let feature = ToolCatalogEntry(
      pluginID: "test.plugin", pluginName: "Test", pluginVersion: "1", source: .user,
      feature: ToolFeature(code: "log", title: "Log", keywords: [], match: [], action: .ui))
    let foreign = ToolCatalogEntry(
      pluginID: "other.plugin", pluginName: "Other", pluginVersion: "1", source: .user,
      feature: ToolFeature(code: "log", title: "Log", keywords: [], match: [], action: .ui))
    harness.features = [feature.id: feature, foreign.id: foreign]
    #expect(await harness.performer.perform(.feature(code: "log", text: "main"), from: bar()) == .performed)
    #expect(harness.launched.map(\.0) == [feature.id])
    #expect(harness.launched.first?.1 == "main")
    #expect(await harness.performer.perform(.feature(code: "missing", text: nil), from: bar()) != .performed)
    #expect(harness.launched.count == 1)
    #expect(await harness.performer.perform(.refresh, from: bar()) == .performed)
    #expect(harness.refreshed == [bar().id])
  }
}
