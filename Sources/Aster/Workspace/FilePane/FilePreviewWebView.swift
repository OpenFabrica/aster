import AppKit
import AsterCore
import WebKit

/// 双模式预览保留 WebKit 的选区、链接和图片菜单，仅插入文件 Chat 并接管读盘重载。
@MainActor
final class FilePreviewWebView: WKWebView {
  var onSendToChat: (() -> Void)?
  var onReloadFromDisk: (() -> Void)?

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    let chatID = NSUserInterfaceItemIdentifier("aster.sendToChat")
    for item in menu.items where item.identifier == chatID { menu.removeItem(item) }
    let clipboardActions = [#selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.paste(_:))]
    let insertion = menu.items.lastIndex { item in
      let title = item.title.lowercased()
      return item.action.map(clipboardActions.contains) == true || title.hasPrefix("copy") || title == "cut" || title == "paste"
    }.map { $0 + 1 } ?? 0
    let chat = ActionMenuItem(title: L("发送到 Chat") + "…") { [weak self] in self?.onSendToChat?() }
    chat.identifier = chatID
    menu.insertItem(chat, at: insertion)
    if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }),
      let old = menu.item(at: index) {
      let reload = ActionMenuItem(title: old.title) { [weak self] in self?.onReloadFromDisk?() }
      reload.identifier = old.identifier
      reload.keyEquivalent = old.keyEquivalent
      reload.keyEquivalentModifierMask = old.keyEquivalentModifierMask
      menu.removeItem(at: index)
      menu.insertItem(reload, at: index)
    }
  }
}
