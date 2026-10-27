// 内置原生工具界面经工厂创建后的主结果：默认方向、输入更新、teardown 后不再响应。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 记录工具界面对会话发出的请求。
@MainActor
private final class BuiltinActionRecorder {
  var copied: [String] = []
  var notices: [String] = []
  var resultChanges = 0
  var heightChanges = 0
  /// 指定时替代 App 当前的终端主题与字体。
  var style: ToolTerminalStyle?

  var actions: BuiltinToolActions {
    BuiltinToolActions(
      copy: { [weak self] text in self?.copied.append(text) },
      insertIntoTerminal: { _ in },
      showNotice: { [weak self] text, _ in self?.notices.append(text) },
      heightDidChange: { [weak self] in self?.heightChanges += 1 },
      resultDidChange: { [weak self] in self?.resultChanges += 1 },
      window: { nil },
      terminalStyle: { [weak self] in self?.style ?? ToolTerminalStyle.current() })
  }
}

@MainActor
struct BuiltinNativeContentTests {
  private let recorder = BuiltinActionRecorder()

  /// 用工厂创建 handler 对应的界面。
  private func make(_ handler: ToolBuiltinHandler, text: String?) -> any BuiltinToolContent {
    BuiltinToolContentFactory.make(handler: handler, input: ToolInput(text: text), actions: recorder.actions)
  }

  @Test func timestampShowsLocalTimeForTimestampsAndSecondsForDates() throws {
    let content = make(.timestamp, text: "1700000000")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(content.primaryResultText == BuiltinTextTools.formatDate(date, timeZone: .current))
    content.update(input: ToolInput(text: "2024-01-01 12:00:00"))
    let local = try #require(BuiltinDateParser.parse("2024-01-01 12:00:00", timeZone: .current))
    #expect(content.primaryResultText == String(Int64(local.timeIntervalSince1970)))
    #expect(recorder.resultChanges == 1)
    content.update(input: ToolInput(text: "not a date"))
    #expect(content.primaryResultText == nil)
  }

  @Test func timestampDefaultsToNowWhenInputIsEmpty() throws {
    let content = make(.timestamp, text: nil)
    let shown = try #require(content.primaryResultText)
    let parsed = try #require(BuiltinDateParser.parse(shown, timeZone: .current))
    #expect(abs(parsed.timeIntervalSinceNow) < 5)
  }

  @Test func base64PicksDirectionFromInput() {
    let content = make(.base64, text: "aGVsbG8=")
    #expect(content.primaryResultText == "hello")
    content.update(input: ToolInput(text: "hello"))
    #expect(content.primaryResultText == "aGVsbG8=")
    #expect(recorder.resultChanges == 1)
  }

  @Test func urlDecodesEncodesAndSplits() {
    let content = make(.url, text: "a%20b")
    #expect(content.primaryResultText == "a b")
    content.update(input: ToolInput(text: "https://x.com/?a=1&b=two+words"))
    #expect(content.primaryResultText == "a=1\nb=two words")
    content.update(input: ToolInput(text: "a b"))
    #expect(content.primaryResultText == "a%20b")
  }

  @Test func hashUsesSHA256AsPrimaryResult() {
    let content = make(.hash, text: "abc")
    #expect(content.primaryResultText == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func uuidPrimaryResultIsVersion4() throws {
    let content = make(.uuid, text: nil)
    let value = try #require(content.primaryResultText)
    #expect(UUID(uuidString: value) != nil)
    #expect(Array(value)[14] == "4")
  }

  @Test func jsonFormatsInBackgroundAndSwitchesWithInput() async throws {
    let content = make(.json, text: #"{"a":[1,2],"b":null}"#)
    let expected = try JSONDocumentFormatter.format(#"{"a":[1,2],"b":null}"#, indent: "  ")
    try await waitUntil { content.primaryResultText == expected }
    content.update(input: ToolInput(text: "[true]"))
    let next = try JSONDocumentFormatter.format("[true]", indent: "  ")
    try await waitUntil { content.primaryResultText == next }
    content.update(input: ToolInput(text: "{broken"))
    try await waitUntil { content.primaryResultText == nil }
  }

  /// 树视图按终端主题自绘底色，明暗要跟主题走：浅色面板配深色终端主题时，按钮文字不能和底色撞色。
  @Test func jsonTreeAppearanceFollowsTerminalTheme() throws {
    let dark = TerminalThemeCatalog.resolve(named: "Ayu Dark", customThemes: [], mode: .dark)
    try #require(dark.mode == .dark)
    recorder.style = ToolTerminalStyle(theme: dark, font: NSFont.interfaceMonospaced(ofSize: 12))
    let content = make(.json, text: "[1]")
    content.view.appearance = NSAppearance(named: .aqua)
    let tree = try #require(descendants(of: content.view).first { $0 is FileJSONTreeView })
    #expect(tree.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    content.teardown()
  }

  @Test func teardownStopsReactingToInput() {
    let content = make(.base64, text: "aGVsbG8=")
    content.teardown()
    content.update(input: ToolInput(text: "d29ybGQ="))
    #expect(content.primaryResultText == "hello")
    #expect(recorder.resultChanges == 0)
  }

  /// 视图本身与它的全部子孙视图。
  private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  /// 轮询等待后台结果（最多 3 秒）。
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }
}
