// 「主机 → 密钥」子页的原生对话框：生成 / 重命名时输入名称，删除与迁移引用前的确认。
// 删除原私钥文件的确认框在 `SSHVaultKeyActions` 里（核对指纹后才弹），这里不重复。
import AppKit
import AsterCore

/// 名称对话框的输入：生成新密钥（名称 + 注释）或重命名（只有名称）。
struct HostsKeyNameRequest: Equatable {
  enum Mode: Equatable {
    case generate
    case rename
  }

  var mode: Mode
  var label = ""
  var comment = ""
  /// 上一次提交失败的原因；非 nil 时显示在说明文字里，输入保留。
  var error: String?
}

/// 名称对话框的结果（未裁剪，服务负责校验与规范化）。
struct HostsKeyNameResult: Equatable {
  var label: String
  var comment: String
}

/// 页面用到的对话框。生产用 `.live`；测试注入替身，不弹真窗口。
struct HostsKeysPrompts {
  /// 输入名称；取消返回 nil。
  var name: @MainActor (HostsKeyNameRequest, NSWindow?) async -> HostsKeyNameResult?
  /// 删除密钥前确认，列出使用它的主机。
  var confirmDelete: @MainActor (SSHVaultKeyRow, NSWindow?) async -> Bool
  /// 改用保险库密钥前确认，列出将要修改的主机。
  var confirmMigrate: @MainActor (SSHVaultKeyRow, NSWindow?) async -> Bool

  /// 生产实现：NSAlert 表单与确认框。
  @MainActor static let live = HostsKeysPrompts(
    name: HostsKeysPrompts.promptName,
    confirmDelete: HostsKeysPrompts.confirmDelete,
    confirmMigrate: HostsKeysPrompts.confirmMigrate)

  // MARK: - 生产实现

  /// 名称表单：名称为空时确认按钮不可用；生成时多一个可选注释。
  @MainActor
  static func promptName(_ request: HostsKeyNameRequest, window: NSWindow?) async -> HostsKeyNameResult? {
    let generating = request.mode == .generate
    let alert = NSAlert()
    alert.messageText = generating ? L("生成新密钥") : L("重命名密钥")
    let intro = generating
      ? L("生成一把 Ed25519 密钥，私钥只保存在钥匙串里。把公钥加到服务器的 authorized_keys 后即可使用。") : ""
    alert.informativeText = request.error.map { intro.isEmpty ? $0 : "\(intro)\n\n\($0)" } ?? intro
    if request.error != nil { alert.alertStyle = .warning }
    alert.addButton(withTitle: generating ? L("生成") : L("保存"))
    alert.addButton(withTitle: L("取消"))

    let labelField = makeField(request.label, placeholder: L("例如：工作笔记本"))
    let commentField = generating ? makeField(request.comment, placeholder: L("可选，写进公钥末尾")) : nil
    var rows: [[NSView]] = [[makeLabel(L("名称"), size: 12), labelField]]
    if let commentField { rows.append([makeLabel(L("注释"), size: 12), commentField]) }
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 8
    grid.columnSpacing = 10
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.frame = NSRect(x: 0, y: 0, width: 320, height: generating ? 58 : 24)
    alert.accessoryView = grid

    // 名称为空时禁用确认按钮，与网页版「名称不能为空」同一规则；其余校验交给服务。
    let confirm = alert.buttons[0]
    let observer = HostsKeyNameFieldObserver(field: labelField, button: confirm)
    labelField.delegate = observer
    observer.update()
    alert.window.initialFirstResponder = labelField

    let response: NSApplication.ModalResponse
    if let window {
      response = await withCheckedContinuation { continuation in
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      }
    } else {
      response = alert.runModal()
    }
    withExtendedLifetime(observer) {}
    guard response == .alertFirstButtonReturn else { return nil }
    return HostsKeyNameResult(label: labelField.stringValue, comment: commentField?.stringValue ?? "")
  }

  /// 删除确认：私钥从钥匙串删除且不能撤销，列出使用它的主机。
  @MainActor
  static func confirmDelete(_ row: SSHVaultKeyRow, window: NSWindow?) async -> Bool {
    var lines = [L("私钥会从钥匙串删除，不能撤销。使用它的主机会去掉这把密钥。")]
    if !row.usedBy.isEmpty {
      lines.append(L("使用它的主机（\(String(row.usedBy.count))）：") + "\n" + row.usedBy.joined(separator: "、"))
    }
    return await confirm(
      title: L("删除“\(row.key.label)”？"), body: lines.joined(separator: "\n\n"),
      button: L("删除"), destructive: true, window: window)
  }

  /// 迁移确认：列出 `identityFiles` 会被换成这把保险库密钥的主机。
  @MainActor
  static func confirmMigrate(_ row: SSHVaultKeyRow, window: NSWindow?) async -> Bool {
    let lines = [
      L("以下主机的私钥文件 \(row.importedFromDisplay ?? "") 会换成保险库密钥“\(row.key.label)”。"),
      L("将要修改的主机（\(String(row.migratableHosts.count))）：") + "\n"
        + row.migratableHosts.joined(separator: "、"),
    ]
    return await confirm(
      title: L("改用保险库密钥？"), body: lines.joined(separator: "\n\n"),
      button: L("改用保险库密钥"), destructive: false, window: window)
  }

  /// 通用确认框：有窗口时作为 sheet，否则模态。
  @MainActor
  private static func confirm(
    title: String, body: String, button: String, destructive: Bool, window: NSWindow?
  ) async -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body
    alert.alertStyle = destructive ? .warning : .informational
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: L("取消"))
    alert.buttons.first?.hasDestructiveAction = destructive
    if let window {
      return await withCheckedContinuation { continuation in
        alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
      }
    }
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// 表单里的单行输入框。
  @MainActor
  private static func makeField(_ value: String, placeholder: String) -> NSTextField {
    let field = NSTextField(string: value)
    field.placeholderString = placeholder
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 250).isActive = true
    field.cell?.isScrollable = true
    field.cell?.wraps = false
    return field
  }
}

/// 名称输入框的观察者：内容变化时同步确认按钮的可用状态。
@MainActor
private final class HostsKeyNameFieldObserver: NSObject, NSTextFieldDelegate {
  private weak var field: NSTextField?
  private weak var button: NSButton?

  /// 记住输入框与确认按钮。
  init(field: NSTextField, button: NSButton) {
    self.field = field
    self.button = button
  }

  /// 名称去空白后非空才可确认。
  func update() {
    button?.isEnabled = !(field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  func controlTextDidChange(_ obj: Notification) { update() }
}
