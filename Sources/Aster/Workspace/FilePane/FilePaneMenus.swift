import AppKit
import AsterCore

/// 文件源码菜单按当前文本视图构建。动作绑定原视图，右键非活动 Pane 也不会误改其他文档。
@MainActor
enum FilePaneMenus {
  static func source(
    textView: NSTextView, syntax: NSMenu, viewAs: NSMenu? = nil,
    reload: (() -> Void)?, sendToChat: @escaping () -> Void
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    func item(_ title: String, key: String = "", enabled: Bool = true, action: @escaping () -> Void) {
      let entry = ActionMenuItem(title: title, handler: action)
      entry.keyEquivalent = key
      entry.isEnabled = enabled
      menu.addItem(entry)
    }
    let selected = textView.selectedRange().length > 0
    item(L("剪切"), key: "x", enabled: textView.isEditable && selected) { [weak textView] in textView?.cut(nil) }
    item(L("复制"), key: "c", enabled: selected) { [weak textView] in textView?.copy(nil) }
    item(L("粘贴"), key: "v", enabled: textView.isEditable) { [weak textView] in textView?.pasteAsPlainText(nil) }
    menu.addItem(.separator())
    item(L("全选"), key: "a") { [weak textView] in textView?.selectAll(nil) }
    if textView.isEditable {
      menu.addItem(.separator())
      // 直接调用 undo manager 会还原 NSTextStorage，却不保证发出 textDidChange；显式通知
      // 文档 delegate，确保保存状态、预览和磁盘保存使用撤销后的内容。
      item(L("撤销"), key: "z", enabled: textView.undoManager?.canUndo == true) { [weak textView] in
        guard let textView, textView.isEditable else { return }
        textView.undoManager?.undo()
        textView.didChangeText()
      }
      item(L("重做"), key: "Z", enabled: textView.undoManager?.canRedo == true) { [weak textView] in
        guard let textView, textView.isEditable else { return }
        textView.undoManager?.redo()
        textView.didChangeText()
      }
    }
    menu.addItem(.separator())
    let language = NSMenuItem(title: L("语法"), action: nil, keyEquivalent: "")
    language.submenu = syntax
    menu.addItem(language)
    if let viewAs {
      let view = NSMenuItem(title: L("显示为"), action: nil, keyEquivalent: "")
      view.submenu = viewAs
      menu.addItem(view)
    }
    if let reload {
      menu.addItem(.separator())
      item(L("从磁盘重新加载"), action: reload)
    }
    menu.addItem(.separator())
    item(L("发送到 Chat") + "…", action: sendToChat)
    return menu
  }

  static func syntax(languages: [String], selected: String?, select: @escaping (String?) -> Void) -> NSMenu {
    let menu = NSMenu()
    let automatic = ActionMenuItem(title: L("自动检测")) { select(nil) }
    automatic.state = selected == nil ? .on : .off
    menu.addItem(automatic)
    menu.addItem(.separator())
    for language in languages {
      let item = ActionMenuItem(title: language) { select(language) }
      item.state = selected == language ? .on : .off
      menu.addItem(item)
    }
    return menu
  }
}
