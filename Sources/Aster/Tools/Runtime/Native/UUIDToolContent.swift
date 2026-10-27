// UUID 与随机串工具：一次生成 5 个 v4、5 个 v7 和一条随机串，可调长度与字符集，每行单独复制。
import AppKit
import AsterCore

/// `uuid` 内置工具的界面。
@MainActor
final class UUIDToolContent: BuiltinToolContent {
  /// 每种 UUID 生成几条。
  private static let uuidCount = 5

  var view: NSView { root }
  var preferredHeight: CGFloat { 390 }
  private(set) var primaryResultText: String?

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let lengthField = BuiltinInputField(placeholder: String(BuiltinRandomLength.defaultLength))
  /// 下拉菜单的顺序与 `ToolRandomAlphabet.allCases` 一致。
  private let alphabetPopUp = BuiltinPopUpButton(titles: [L("字母和数字"), L("十六进制"), L("字母、数字和符号")])
  private let list: BuiltinScrollingResultList
  private let hint = BuiltinToolLayout.hintLabel()
  private var length = BuiltinRandomLength.defaultLength
  private var alphabet = ToolRandomAlphabet.alphanumeric
  private var uuidLines: [ToolResultLine] = []
  private var randomLine = ToolResultLine(label: "", value: "")
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    list = BuiltinScrollingResultList(labelWidth: 52) { text in actions.copy(text) }
    lengthField.stringValue = String(BuiltinRandomLength.defaultLength)
    lengthField.widthAnchor.constraint(equalToConstant: 64).isActive = true
    let lengthLabel = makeLabel(L("随机串长度"), size: 11, color: AsterTheme.secondaryInk)
    let regenerate = BuiltinToolLayout.button(L("重新生成"), symbol: "arrow.clockwise") { [weak self] in
      self?.regenerateAll()
    }
    let toolbar = BuiltinToolLayout.toolbar(leading: [lengthLabel, lengthField, alphabetPopUp], trailing: [regenerate])
    let card = BuiltinToolCard(content: list)
    root.install(arranged: [toolbar, card, hint], expanding: card)
    lengthField.onChange = { [weak self] text in self?.lengthChanged(text) }
    alphabetPopUp.onChange = { [weak self] index in self?.alphabetChanged(index) }
    regenerateAll()
    isReady = true
  }

  /// 生成器不看输入。
  func update(input: ToolInput) {}

  func teardown() {
    isTornDown = true
    lengthField.onChange = nil
    alphabetPopUp.onChange = nil
  }

  /// 「重新生成」：UUID 与随机串全部换新。
  private func regenerateAll() {
    guard !isTornDown else { return }
    let now = Date()
    uuidLines =
      (0..<Self.uuidCount).map { _ in ToolResultLine(label: "v4", value: BuiltinTextTools.uuidV4()) }
      + (0..<Self.uuidCount).map { _ in ToolResultLine(label: "v7", value: BuiltinTextTools.uuidV7(now: now)) }
    regenerateRandom()
  }

  /// 只换随机串（改长度或字符集时 UUID 不动）。
  private func regenerateRandom() {
    randomLine = ToolResultLine(
      label: L("随机串"), value: BuiltinTextTools.randomString(length: length, alphabet: alphabet))
    list.setLines(uuidLines + [randomLine])
    let previous = primaryResultText
    primaryResultText = uuidLines.first?.value
    if previous != primaryResultText, isReady { actions.resultDidChange() }
  }

  /// 长度输入：不是 1–4096 的整数时提示，保留上一条随机串。
  private func lengthChanged(_ text: String) {
    guard !isTornDown else { return }
    guard let value = BuiltinRandomLength.parse(text) else {
      BuiltinToolLayout.setHint(hint, L("长度需要是 1 到 4096 之间的整数"), isError: true)
      return
    }
    BuiltinToolLayout.setHint(hint, nil)
    length = value
    regenerateRandom()
  }

  /// 字符集切换。
  private func alphabetChanged(_ index: Int) {
    guard !isTornDown, ToolRandomAlphabet.allCases.indices.contains(index) else { return }
    alphabet = ToolRandomAlphabet.allCases[index]
    regenerateRandom()
  }
}
