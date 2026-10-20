// 验证终端浮层在绘制上下文与窗口外观不一致时仍使用成对的主题颜色。
import AppKit
import AsterCore
import Testing

@testable import Aster

@Suite(.serialized)
@MainActor
struct TerminalOverlayAppearanceTests {
  @Test("补全面板按自身外观解析动态背景，不受调用方绘制上下文影响")
  func autocompleteUsesEffectiveAppearance() throws {
    let light = try #require(NSAppearance(named: .aqua))
    let dark = try #require(NSAppearance(named: .darkAqua))
    let overlay = TerminalAutocompleteOverlayView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    overlay.appearance = dark
    light.performAsCurrentDrawingAppearance {
      overlay.render(
        result: AutocompleteResult(candidates: [
          AutocompleteCandidate(insertText: "git status", description: "查看工作区状态", kind: .command),
          AutocompleteCandidate(insertText: "git diff", kind: .command),
        ], ghostText: nil, replacementStart: 0),
        showInline: false, showPanel: true, selectedIndex: 0,
        caretFrame: NSRect(x: 24, y: 300, width: 8, height: 18),
        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
        foreground: AsterTheme.ink, background: AsterTheme.panel, accent: AsterTheme.accent)
    }
    try expectBackground(of: overlay.panelContainer, appearance: dark, alpha: 0.97)
    let selected = try #require(overlay.panel.arrangedSubviews.first as? AutocompleteCandidateRow)
    try expectColor(selected.layer?.backgroundColor, matches: AsterTheme.accent,
      appearance: dark, alpha: 0.15)
    try expectColor(overlay.panelContainer.layer?.borderColor, matches: AsterTheme.ink,
      appearance: dark, alpha: 0.18)
    try expectColor(overlay.descriptionSidebar.layer?.backgroundColor, matches: AsterTheme.ink,
      appearance: dark, alpha: 0.045)
    overlay.appearance = light
    try expectBackground(of: overlay.panelContainer, appearance: light, alpha: 0.97)
    try expectColor(selected.layer?.backgroundColor, matches: AsterTheme.accent,
      appearance: light, alpha: 0.15)
    overlay.appearance = dark
    try expectBackground(of: overlay.panelContainer, appearance: dark, alpha: 0.97)
    // 实际控制器先渲染、再挂进终端窗口，覆盖继承外观改变的路径。
    overlay.appearance = nil
    let window = NSWindow(contentRect: overlay.bounds, styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = dark
    window.contentView = overlay
    try expectBackground(of: overlay.panelContainer, appearance: dark, alpha: 0.97)
  }

  @Test("会话状态提示按窗口外观解析背景并跟随明暗切换")
  func sessionNoticeUsesEffectiveAppearance() throws {
    let suite = "TerminalOverlayAppearance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let tab = WorkspaceTabSnapshot(
      id: UUID(), title: "theme-test",
      layout: .leaf(PaneDescriptor(kind: .editor, workingDirectory: NSTemporaryDirectory())))
    defaults.set(try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
      forKey: "aster.workspace.snapshot.v1")
    let model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    let message = "Claude Code 会话已结束 · claude --resume example · 在此项目新开终端时补全首选"
    model.notice = message
    let controller = WorkspaceViewController(model: model, preferences: AppPreferences(defaults: defaults))
    let light = try #require(NSAppearance(named: .aqua))
    let dark = try #require(NSAppearance(named: .darkAqua))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = dark
    light.performAsCurrentDrawingAppearance {
      window.contentViewController = controller
    }
    let toast = try #require(descendants(of: controller.view).compactMap { $0 as? NSTextField }
      .first { $0.stringValue == message })
    try expectBackground(of: toast, appearance: dark, alpha: 0.95)
    try expectColor(toast.layer?.borderColor, matches: AsterTheme.hairline, appearance: dark)
    window.appearance = light
    try expectBackground(of: toast, appearance: light, alpha: 0.95)
    window.appearance = dark
    try expectBackground(of: toast, appearance: dark, alpha: 0.95)
  }

  private func expectBackground(of view: NSView, appearance: NSAppearance, alpha: CGFloat) throws {
    try expectColor(view.layer?.backgroundColor, matches: AsterTheme.panel,
      appearance: appearance, alpha: alpha)
  }

  private func expectColor(_ color: CGColor?, matches expectedColor: NSColor,
    appearance: NSAppearance, alpha: CGFloat? = nil) throws {
    let actual = try #require(color.flatMap(NSColor.init(cgColor:)))
    var expected = NSColor.clear
    appearance.performAsCurrentDrawingAppearance {
      let value = alpha.map { expectedColor.withAlphaComponent($0) } ?? expectedColor
      expected = value.usingColorSpace(.sRGB) ?? .clear
    }
    #expect(HexColor(nsColor: actual) == HexColor(nsColor: expected))
  }

  private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}
