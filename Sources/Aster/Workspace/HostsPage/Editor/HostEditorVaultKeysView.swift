// 编辑面板「保险库密钥」一行：每把密钥一个复选框，下方说明随勾选变化（未勾选时说明继承哪几把）。
import AppKit
import AsterCore

/// 保险库密钥勾选列表。选择结果保存在 `selection`，保持原顺序，勾选新密钥追加到末尾；
/// 保险库里找不到的 ID 原样保留，避免从编辑器保存时悄悄丢掉引用。
@MainActor
final class HostEditorVaultKeysView: NSStackView {
  /// 当前选择（含保险库里已不存在的 ID）。
  private(set) var selection: [UUID]
  private let isDefaults: Bool
  /// 默认项引用的密钥，未勾选时提示会继承它们。
  private let inheritedIDs: [UUID]
  private var keys: [SSHVaultKey] = []
  private var checks: [(id: UUID, button: NSButton)] = []
  private let list = NSStackView()
  private let hint = makeHostEditorHint("")

  /// `selection` 为主机当前引用；`keys` 为保险库里的密钥（保存顺序）。
  init(selection: [UUID], keys: [SSHVaultKey], inheritedIDs: [UUID], isDefaults: Bool) {
    self.selection = selection
    self.isDefaults = isDefaults
    self.inheritedIDs = inheritedIDs
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("host-editor-vault-keys")
    orientation = .vertical
    alignment = .leading
    spacing = 6
    translatesAutoresizingMaskIntoConstraints = false
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 4
    addArrangedSubview(list)
    addArrangedSubview(hint)
    hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    setKeys(keys)
  }

  required init?(coder: NSCoder) { nil }

  /// 保险库内容变化时重建勾选列表；用户已做的选择保留。
  func setKeys(_ keys: [SSHVaultKey]) {
    self.keys = keys
    list.arrangedSubviews.forEach { $0.removeFromSuperview() }
    checks = []
    let selected = Set(selection)
    for key in keys {
      let check = NSButton(checkboxWithTitle: key.label, target: self, action: #selector(toggled(_:)))
      check.identifier = NSUserInterfaceItemIdentifier("host-editor-vault-key-\(key.id.uuidString)")
      check.font = NSFont.interface(ofSize: 12.5)
      check.state = selected.contains(key.id) ? .on : .off
      check.setAccessibilityLabel(key.label)
      let fingerprint = makeLabel(Self.shortFingerprint(key.fingerprint), size: 11, color: AsterTheme.tertiaryInk, monospaced: true)
      fingerprint.toolTip = key.fingerprint
      let row = NSStackView(views: [check, fingerprint])
      row.orientation = .horizontal
      row.spacing = 8
      list.addArrangedSubview(row)
      checks.append((key.id, check))
    }
    list.isHidden = keys.isEmpty
    updateHint()
  }

  /// 短指纹：`SHA256:` 后取前 16 个字符，完整值放在提示里（与「密钥」页一致）。
  static func shortFingerprint(_ fingerprint: String) -> String {
    guard fingerprint.hasPrefix("SHA256:") else { return fingerprint }
    let body = fingerprint.dropFirst("SHA256:".count)
    return body.count > 16 ? "SHA256:\(body.prefix(16))…" : fingerprint
  }

  /// 勾选变化：更新选择并刷新提示。
  @objc private func toggled(_ sender: NSButton) {
    guard let id = checks.first(where: { $0.button === sender })?.id else { return }
    selection.removeAll { $0 == id }
    if sender.state == .on { selection.append(id) }
    updateHint()
  }

  /// 测试与键盘操作用：直接设置某把密钥的勾选状态。
  func setSelected(_ id: UUID, _ selected: Bool) {
    guard let button = checks.first(where: { $0.id == id })?.button else { return }
    button.state = selected ? .on : .off
    toggled(button)
  }

  /// 提示文案：没有密钥、未勾选时继承默认、或说明尝试顺序。
  private func updateHint() {
    let knownSelected = selection.contains { id in keys.contains { $0.id == id } }
    let inheritedNames = inheritedIDs.compactMap { id in keys.first { $0.id == id }?.label }
    if keys.isEmpty {
      hint.stringValue = L("还没有保险库密钥，可在「密钥」标签页导入或生成")
    } else if !isDefaults && !inheritedNames.isEmpty && !knownSelected {
      hint.stringValue = L("未选择时继承默认：\(inheritedNames.joined(separator: "、"))")
    } else {
      hint.stringValue = L("勾选的密钥先于私钥文件尝试；私钥只保存在钥匙串里")
    }
  }
}
