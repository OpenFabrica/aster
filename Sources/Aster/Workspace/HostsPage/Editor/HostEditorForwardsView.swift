// 编辑面板「端口转发」分区：每条规则一张小卡片（类型、说明、移除；绑定 → 目标），可增删。
import AppKit
import AsterCore

/// 端口转发规则列表。规则文本保存在 `rules`，组装与校验交给 `SSHHostDraft`。
@MainActor
final class HostEditorForwardsView: NSStackView {
  private(set) var rules: [SSHHostDraft.Forward]
  /// 默认项里先生效的规则数（编辑默认项时为 0）。
  private let defaultRuleCount: Int
  /// 每张卡片对应的控件；重建前先把输入同步回 `rules`。
  private var rows: [Row] = []
  private let list = NSStackView()
  /// 规则内输入框的代理（编辑面板，用于 Esc 关闭与回车保存）。
  private weak var fieldDelegate: NSTextFieldDelegate?

  private struct Row {
    var kind: HostEditorPopUp
    var bind: HostEditorTextField
    var target: HostEditorTextField
    var note: HostEditorTextField
  }

  /// `rules` 为主机当前规则的草稿；`defaultRuleCount` 用来提示默认项规则会先生效。
  init(rules: [SSHHostDraft.Forward], defaultRuleCount: Int, fieldDelegate: NSTextFieldDelegate?) {
    self.rules = rules
    self.defaultRuleCount = defaultRuleCount
    self.fieldDelegate = fieldDelegate
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("host-editor-forwards")
    orientation = .vertical
    alignment = .leading
    spacing = 8
    translatesAutoresizingMaskIntoConstraints = false
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 8
    list.translatesAutoresizingMaskIntoConstraints = false
    addArrangedSubview(list)
    list.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    let add = HostEditorButton(title: L("+ 添加规则"), style: .secondary) { [weak self] in self?.addRule() }
    add.identifier = NSUserInterfaceItemIdentifier("host-editor-add-forward")
    addArrangedSubview(add)
    rebuild()
  }

  required init?(coder: NSCoder) { nil }

  /// 读出当前全部规则（含正在输入的内容）。
  func currentRules() -> [SSHHostDraft.Forward] {
    syncFromControls()
    return rules
  }

  /// 追加一条空的本地转发规则，并把焦点放到它的绑定地址。
  func addRule() {
    syncFromControls()
    rules.append(SSHHostDraft.Forward())
    rebuild()
    if let last = rows.last { window?.makeFirstResponder(last.bind.field) }
  }

  /// 移除第 `index` 条规则。
  func removeRule(at index: Int) {
    syncFromControls()
    guard rules.indices.contains(index) else { return }
    rules.remove(at: index)
    rebuild()
  }

  /// 把控件里的输入写回 `rules`。
  private func syncFromControls() {
    for (index, row) in rows.enumerated() where rules.indices.contains(index) {
      rules[index].kind = row.kind.selectedValue as? SSHForwardKind ?? .local
      rules[index].bind = row.bind.stringValue
      rules[index].target = row.target.stringValue
      rules[index].description = row.note.stringValue
    }
  }

  /// 按 `rules` 重建提示与卡片。
  private func rebuild() {
    list.arrangedSubviews.forEach { $0.removeFromSuperview() }
    rows = []
    var views: [NSView] = []
    if defaultRuleCount > 0 {
      views.append(makeHostEditorHint(L("「默认」项里的 \(String(defaultRuleCount)) 条规则会先生效。")))
    }
    if rules.isEmpty { views.append(makeHostEditorHint(L("还没有转发规则。"))) }
    for (index, rule) in rules.enumerated() { views.append(makeCard(rule, index: index)) }
    for view in views {
      list.addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }
  }

  /// 一条规则的卡片：第一行类型 + 说明 + 移除，第二行绑定 → 目标。
  private func makeCard(_ rule: SSHHostDraft.Forward, index: Int) -> NSView {
    let card = HostsPageFilledView(fillColor: HostsPagePalette.ruleCard, cornerRadius: 9)
    card.identifier = NSUserInterfaceItemIdentifier("host-editor-forward-\(index)")
    card.translatesAutoresizingMaskIntoConstraints = false
    let kind = HostEditorPopUp(identifier: "host-editor-forward-kind-\(index)")
    for value in SSHForwardKind.allCases { kind.addItem(Self.kindLabel(value), value: value) }
    kind.select { ($0 as? SSHForwardKind) == rule.kind }
    let note = HostEditorTextField(placeholder: L("说明"), identifier: "host-editor-forward-note-\(index)")
    note.stringValue = rule.description
    let remove = IconHoverButton(symbol: "xmark", accessibilityDescription: L("移除规则 \(String(index + 1))")) {
      [weak self] in self?.removeRule(at: index)
    }
    remove.identifier = NSUserInterfaceItemIdentifier("host-editor-forward-remove-\(index)")
    remove.toolTip = L("移除规则 \(String(index + 1))")
    let bind = HostEditorTextField(
      placeholder: L("绑定 127.0.0.1:8080"), identifier: "host-editor-forward-bind-\(index)", monospaced: true)
    bind.stringValue = rule.bind
    let arrow = makeLabel("→", size: 12, color: AsterTheme.tertiaryInk)
    let target = HostEditorTextField(
      placeholder: L("目标 localhost:80"), identifier: "host-editor-forward-target-\(index)", monospaced: true)
    target.stringValue = rule.target
    target.field.isEnabled = rule.kind != .dynamic
    kind.popUp.target = self
    kind.popUp.action = #selector(kindChanged(_:))
    kind.popUp.tag = index
    for field in [note, bind, target] { field.field.delegate = fieldDelegate }

    for view in [kind, note, remove, bind, arrow, target] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(view)
    }
    let pad: CGFloat = 8
    NSLayoutConstraint.activate([
      kind.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
      kind.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
      kind.widthAnchor.constraint(equalToConstant: 104),
      note.centerYAnchor.constraint(equalTo: kind.centerYAnchor),
      note.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: 6),
      remove.leadingAnchor.constraint(equalTo: note.trailingAnchor, constant: 4),
      remove.centerYAnchor.constraint(equalTo: kind.centerYAnchor),
      remove.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad + 2),
      remove.widthAnchor.constraint(equalToConstant: 24),
      remove.heightAnchor.constraint(equalToConstant: 24),
      bind.topAnchor.constraint(equalTo: kind.bottomAnchor, constant: 6),
      bind.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
      arrow.leadingAnchor.constraint(equalTo: bind.trailingAnchor, constant: 6),
      arrow.centerYAnchor.constraint(equalTo: bind.centerYAnchor),
      target.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 6),
      target.centerYAnchor.constraint(equalTo: bind.centerYAnchor),
      target.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
      target.widthAnchor.constraint(equalTo: bind.widthAnchor),
      card.bottomAnchor.constraint(equalTo: bind.bottomAnchor, constant: pad),
    ])
    rows.append(Row(kind: kind, bind: bind, target: target, note: note))
    return card
  }

  /// 类型切换：动态转发没有目标地址，目标框灰显。
  @objc private func kindChanged(_ sender: NSPopUpButton) {
    guard rows.indices.contains(sender.tag) else { return }
    let isDynamic = (sender.selectedItem?.representedObject as? SSHForwardKind) == .dynamic
    rows[sender.tag].target.field.isEnabled = !isDynamic
  }

  /// 转发类型在下拉里的文案。
  static func kindLabel(_ kind: SSHForwardKind) -> String {
    switch kind {
    case .local: L("L 本地")
    case .remote: L("R 远端")
    case .dynamic: L("D 动态")
    }
  }
}
