import AppKit
import PDFKit
import Quartz
import AsterCore

/// 系统文档、图片和 PDF 的查看菜单，与双模式 WebKit 选区菜单分别处理。
@MainActor
enum FileNativePreviewMenus {
  /// Quick Look 的系统子视图可通过远程 responder 处理编辑命令，不一定是本进程 NSView。
  /// 与 Otty 一样保留 nil target，由 AppKit 找到接收者并验证当前选区。
  static func quickLook(send: @escaping () -> Void, fileActions: NSMenu) -> NSMenu {
    let menu = make(copy: nil, selectAll: nil, send: send, fileActions: fileActions)
    menu.removeItem(at: 0)
    menu.removeItem(at: 0)
    menu.insertItem(NSMenuItem(title: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"), at: 0)
    menu.insertItem(NSMenuItem(title: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"), at: 1)
    menu.autoenablesItems = true
    return menu
  }

  static func make(copy: (() -> Void)?, selectAll: (() -> Void)?,
    send: @escaping () -> Void, fileActions: NSMenu) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let copyItem = ActionMenuItem(title: L("复制")) { copy?() }
    copyItem.keyEquivalent = "c"
    copyItem.isEnabled = copy != nil
    menu.addItem(copyItem)
    let all = ActionMenuItem(title: L("全选")) { selectAll?() }
    all.keyEquivalent = "a"
    all.isEnabled = selectAll != nil
    menu.addItem(all)
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: L("发送到 Chat") + "…", handler: send))
    menu.addItem(.separator())
    for item in fileActions.items { fileActions.removeItem(item); menu.addItem(item) }
    return menu
  }
}

@MainActor
final class FilePreviewImageView: NSImageView {
  var contextMenuProvider: (() -> NSMenu)?
  override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
}

@MainActor
final class FilePreviewPDFView: PDFView {
  var contextMenuProvider: (() -> NSMenu)?
  override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
}

@MainActor
final class FileQuickLookPreviewView: QLPreviewView {
  var contextMenuProvider: (() -> NSMenu)?
  override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
}
