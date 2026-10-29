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
  /// 双击回调：图片预览用它在「适应窗口」与 100% 之间切换。
  var onDoubleClick: (() -> Void)?
  override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }

  /// 图片可平移时显示张开的手，提示可以按住拖动。
  override func resetCursorRects() {
    addCursorRect(visibleRect, cursor: isPannable ? .openHand : .arrow)
  }

  /// 双击切换缩放；单击按住拖动平移可视区。滚轮与触控板滚动仍由 NSScrollView 处理。
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      onDoubleClick?()
      return
    }
    guard isPannable, let scrollView = enclosingScrollView, let window else { return }
    let clip = scrollView.contentView
    NSCursor.closedHand.push()
    defer {
      NSCursor.pop()
      window.invalidateCursorRects(for: self)
    }
    var last = event.locationInWindow
    // 自建拖动循环：只消费本次按下到松开之间的拖动事件，不影响其它视图。
    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
      next.type == .leftMouseDragged
    {
      let point = next.locationInWindow
      // 窗口坐标的位移按当前倍率换算到文档坐标；内容跟着鼠标走，可视区原点反向移动。
      let magnification = max(scrollView.magnification, 0.0001)
      var origin = clip.bounds.origin
      origin.x -= (point.x - last.x) / magnification
      origin.y -= (point.y - last.y) / magnification * (isFlipped ? -1 : 1)
      let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
      clip.scroll(to: constrained.origin)
      scrollView.reflectScrolledClipView(clip)
      last = point
    }
  }

  /// 图片在任一方向超出可视区时才可拖动。
  private var isPannable: Bool {
    guard let scrollView = enclosingScrollView else { return false }
    let visible = scrollView.contentView.bounds.size
    return frame.width > visible.width + 0.5 || frame.height > visible.height + 0.5
  }
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
