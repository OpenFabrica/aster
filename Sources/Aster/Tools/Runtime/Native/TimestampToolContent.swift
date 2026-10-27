// 时间戳转换工具：秒 / 毫秒时间戳与常见日期写法互转，每种写法一行可单独复制。
import AppKit
import AsterCore

/// `timestamp` 内置工具的界面。
@MainActor
final class TimestampToolContent: BuiltinToolContent {
  var view: NSView { root }
  var preferredHeight: CGFloat { 230 }
  private(set) var primaryResultText: String?

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let field = BuiltinInputField(placeholder: L("时间戳或日期，如 1700000000、2024-01-01 12:00:00"))
  private let results: BuiltinResultListView
  private let hint = BuiltinToolLayout.hintLabel()
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    results = BuiltinResultListView(labelWidth: 72) { text in actions.copy(text) }
    let now = BuiltinToolLayout.button(L("现在"), symbol: "clock") { [weak self] in self?.showNow() }
    let inputRow = NSStackView(views: [field, now])
    inputRow.orientation = .horizontal
    inputRow.alignment = .centerY
    inputRow.distribution = .fill
    inputRow.spacing = 8
    // 输入框没有固有宽度，`.fill` 让它吃掉按钮以外的整行。
    field.setContentHuggingPriority(.init(1), for: .horizontal)
    let card = BuiltinToolCard(content: results)
    root.install(arranged: [inputRow, card, hint], expanding: card)
    field.onChange = { [weak self] _ in self?.recompute() }
    apply(text: input.text)
    isReady = true
  }

  func update(input: ToolInput) {
    guard !isTornDown else { return }
    apply(text: input.text)
  }

  func teardown() {
    isTornDown = true
    field.onChange = nil
  }

  /// 输入为空时显示当前时间，否则显示输入原文。
  private func apply(text: String?) {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    field.stringValue = trimmed.isEmpty ? Self.nowText() : trimmed
    recompute()
  }

  /// 「现在」按钮：填入当前秒级时间戳。
  private func showNow() {
    guard !isTornDown else { return }
    field.stringValue = Self.nowText()
    recompute()
  }

  /// 按输入重算各行：时间戳 → 日期，日期 → 时间戳；都认不出时显示提示。
  private func recompute() {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeZone = TimeZone.current
    let previous = primaryResultText
    if let date = BuiltinTextTools.parseTimestamp(text) {
      show(date, timeZone: timeZone)
      primaryResultText = BuiltinTextTools.formatDate(date, timeZone: timeZone)
    } else if let date = BuiltinDateParser.parse(text, timeZone: timeZone) {
      show(date, timeZone: timeZone)
      primaryResultText = String(Int64(date.timeIntervalSince1970.rounded(.down)))
    } else {
      results.setLines([])
      primaryResultText = nil
      let message = text.isEmpty ? nil : L("认不出这个时间戳或日期：支持 10 位秒、13 位毫秒，或 2024-01-01 12:00:00 这类日期")
      BuiltinToolLayout.setHint(hint, message, isError: true)
    }
    if previous != primaryResultText, isReady { actions.resultDidChange() }
  }

  /// 显示一个时刻的各种写法，外加相对现在的时间。
  private func show(_ date: Date, timeZone: TimeZone) {
    var lines = BuiltinTextTools.describeTimestamp(date, timeZone: timeZone)
    lines.append(ToolResultLine(label: L("相对现在"), value: RelativeTime.string(since: date)))
    results.setLines(lines)
    BuiltinToolLayout.setHint(hint, nil)
  }

  /// 当前秒级时间戳文本。
  private static func nowText() -> String {
    String(Int64(Date().timeIntervalSince1970))
  }
}
