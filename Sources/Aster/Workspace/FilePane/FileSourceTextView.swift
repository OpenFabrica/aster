// 源码编辑器的右键菜单由文件 Pane 提供，避免富文本系统菜单混入代码编辑操作。
import AppKit
import AsterCore

@MainActor
final class FileSourceTextView: NSTextView {
  var contextMenuProvider: (() -> NSMenu)?

  override func menu(for event: NSEvent) -> NSMenu? {
    contextMenuProvider?() ?? super.menu(for: event)
  }
}
