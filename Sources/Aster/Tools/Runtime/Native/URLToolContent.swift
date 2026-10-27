// URL 编解码工具：编码、解码与拆参数三个方向；拆参数时 URL 各部分与每个参数各占一行，可单独复制。
import AppKit
import AsterCore

/// `url` 内置工具的界面。
@MainActor
final class URLToolContent: BuiltinToolContent {
  var view: NSView { root }
  var preferredHeight: CGFloat { 360 }
  private(set) var primaryResultText: String?

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let segments = BuiltinSegmentedControl(labels: [L("编码"), L("解码"), L("拆参数")])
  private let inputArea = BuiltinTextArea(placeholder: L("输入 URL 或要编码的文本"), editable: true)
  private let outputArea = BuiltinTextArea(placeholder: L("结果"), editable: false)
  private let partsList: BuiltinScrollingResultList
  private let partsCard: BuiltinToolCard
  /// 结果区：编码 / 解码显示文本，拆参数显示各行；两者叠放，按模式切换显隐。
  private let resultArea = NSView()
  private let hint = BuiltinToolLayout.hintLabel()
  private var mode = BuiltinURLMode.encode
  /// 用户手动切过方向后不再自动判断。
  private var userChoseMode = false
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    partsList = BuiltinScrollingResultList(labelWidth: 110) { text in actions.copy(text) }
    partsCard = BuiltinToolCard(content: partsList)
    BuiltinToolLayout.fixHeight(inputArea, 84)
    for view in [outputArea, partsCard] as [NSView] {
      resultArea.addSubview(view)
      view.pinEdges(to: resultArea)
    }
    let copy = BuiltinToolLayout.button(L("复制结果"), symbol: "doc.on.doc") { [weak self] in self?.copyResult() }
    let toolbar = BuiltinToolLayout.toolbar(leading: [segments], trailing: [copy])
    root.install(arranged: [toolbar, inputArea, resultArea, hint], expanding: resultArea)
    segments.onChange = { [weak self] index in self?.selectMode(index) }
    inputArea.onChange = { [weak self] _ in self?.inputDidChange() }
    apply(text: input.text ?? "")
    isReady = true
  }

  func update(input: ToolInput) {
    guard !isTornDown else { return }
    apply(text: input.text ?? "")
  }

  func teardown() {
    isTornDown = true
    segments.onChange = nil
    inputArea.onChange = nil
  }

  /// 换输入并重算。
  private func apply(text: String) {
    inputArea.string = text
    inputDidChange()
  }

  /// 输入变化：没手动选过方向时按内容判断，再重算。
  private func inputDidChange() {
    if !userChoseMode { mode = BuiltinURLMode.preferred(for: inputArea.string) }
    segments.selectedSegment = mode.rawValue
    recompute()
  }

  /// 分段切换：记住用户的选择。
  private func selectMode(_ index: Int) {
    guard !isTornDown, let selected = BuiltinURLMode(rawValue: index) else { return }
    userChoseMode = true
    mode = selected
    recompute()
  }

  /// 按当前模式重算结果与主结果。
  private func recompute() {
    let text = inputArea.string
    let previous = primaryResultText
    var message: String?
    outputArea.isHidden = mode == .split
    partsCard.isHidden = mode != .split
    switch mode {
    case .encode:
      let result = text.isEmpty ? "" : BuiltinTextTools.urlEncode(text)
      outputArea.string = result
      primaryResultText = result.isEmpty ? nil : result
    case .decode:
      let result = text.isEmpty ? "" : BuiltinTextTools.urlDecode(text)
      if result == nil { message = L("包含无效的 % 编码") }
      outputArea.string = result ?? ""
      primaryResultText = (result ?? "").isEmpty ? nil : result
    case .split:
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let parts = BuiltinURLParts.parse(trimmed)
      partsList.setLines(parts?.lines ?? [])
      if let parts {
        // 有参数时主结果是解码后的「名=值」多行，没有参数时退回解码后的整串。
        primaryResultText = parts.parametersText ?? (BuiltinTextTools.urlDecode(trimmed) ?? trimmed)
      } else {
        primaryResultText = nil
        if !trimmed.isEmpty { message = L("不是完整的 URL（需要 http:// 这类协议）或 a=1&b=2 这样的查询串") }
      }
    }
    BuiltinToolLayout.setHint(hint, message, isError: true)
    if previous != primaryResultText, isReady { actions.resultDidChange() }
  }

  /// 「复制结果」按钮。
  private func copyResult() {
    guard let primaryResultText else { return }
    actions.copy(primaryResultText)
  }
}
