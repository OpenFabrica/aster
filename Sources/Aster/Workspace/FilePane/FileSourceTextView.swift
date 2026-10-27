// 源码编辑器的右键菜单由文件 Pane 提供，避免富文本系统菜单混入代码编辑操作。
import AppKit
import AsterCore

@MainActor
final class FileSourceTextView: NSTextView {
  var contextMenuProvider: (() -> NSMenu)?

  override func menu(for event: NSEvent) -> NSMenu? {
    contextMenuProvider?() ?? super.menu(for: event)
  }

  /// 整篇替换文本（如 JSON 格式化）。走 shouldChange/didChange 通道，所以能 ⌘Z 撤销，
  /// 文档 delegate 也会收到变更并标记未保存；不会自动写盘。
  func replaceAllText(_ text: String) {
    let range = NSRange(location: 0, length: (string as NSString).length)
    guard isEditable, shouldChangeText(in: range, replacementString: text) else { return }
    textStorage?.replaceCharacters(in: range, with: text)
    didChangeText()
    setSelectedRange(NSRange(location: 0, length: 0))
    scrollRangeToVisible(NSRange(location: 0, length: 0))
  }
}
