// Base64 编解码工具：上面输入、下面结果；默认按输入能否解码自动选方向，用户切换后以用户为准。
import AppKit
import AsterCore

/// `base64` 内置工具的界面。
@MainActor
final class Base64ToolContent: BuiltinToolContent {
  /// 两个方向；原始值是分段控件的下标。
  private enum Mode: Int {
    case encode
    case decode
  }

  var view: NSView { root }
  var preferredHeight: CGFloat { 340 }
  private(set) var primaryResultText: String?

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let segments = BuiltinSegmentedControl(labels: [L("编码"), L("解码")])
  private let inputArea = BuiltinTextArea(placeholder: L("输入要编码或解码的文本"), editable: true)
  private let outputArea = BuiltinTextArea(placeholder: L("结果"), editable: false)
  private let hint = BuiltinToolLayout.hintLabel()
  private var mode = Mode.encode
  /// 用户手动切过方向后不再自动判断，避免继续输入时方向来回跳。
  private var userChoseMode = false
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    BuiltinToolLayout.fixHeight(inputArea, 110)
    let copy = BuiltinToolLayout.button(L("复制结果"), symbol: "doc.on.doc") { [weak self] in self?.copyResult() }
    let toolbar = BuiltinToolLayout.toolbar(leading: [segments], trailing: [copy])
    root.install(arranged: [toolbar, inputArea, outputArea, hint], expanding: outputArea)
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

  /// 换输入：没手动选过方向时按内容重新判断。
  private func apply(text: String) {
    inputArea.string = text
    inputDidChange()
  }

  /// 输入变化：自动判断方向（除非用户已手动选择）并重算。
  private func inputDidChange() {
    if !userChoseMode {
      mode = BuiltinBase64.prefersDecoding(inputArea.string) ? .decode : .encode
    }
    segments.selectedSegment = mode.rawValue
    recompute()
  }

  /// 分段切换：记住用户的选择。
  private func selectMode(_ index: Int) {
    guard !isTornDown, let selected = Mode(rawValue: index) else { return }
    userChoseMode = true
    mode = selected
    recompute()
  }

  /// 按当前方向算出结果；解码失败时清空结果并提示。
  private func recompute() {
    let text = inputArea.string
    let previous = primaryResultText
    var result: String?
    var message: String?
    if !text.isEmpty {
      switch mode {
      case .encode:
        result = BuiltinTextTools.base64Encode(text)
      case .decode:
        result = BuiltinBase64.decode(text)
        if result == nil { message = L("不是有效的 Base64，或者解码结果不是 UTF-8 文本") }
      }
    }
    outputArea.string = result ?? ""
    BuiltinToolLayout.setHint(hint, message, isError: true)
    primaryResultText = (result ?? "").isEmpty ? nil : result
    if previous != primaryResultText, isReady { actions.resultDidChange() }
  }

  /// 「复制结果」按钮。
  private func copyResult() {
    guard let primaryResultText else { return }
    actions.copy(primaryResultText)
  }
}
