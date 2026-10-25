// 无箭头的 Pane 顶部菜单窗口，复用既有内容与级联菜单交互。
import AppKit
import Combine

@MainActor
final class WorkspaceTitlePanel: NSPanel {
  private let menuContent: WorkspaceTitlePopoverViewController
  private var ownerCloseObserver: AnyCancellable?
  private var isClosing = false
  var onClose: (() -> Void)?
  var isShown: Bool { isVisible }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(content: WorkspaceTitlePopoverViewController) {
    menuContent = content
    super.init(contentRect: NSRect(origin: .zero,
      size: WorkspaceTitlePopoverViewController.preferredSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    contentViewController = content
    let root = content.view
    root.wantsLayer = true
    root.layer?.cornerRadius = 10
    root.layer?.masksToBounds = true
    root.layer?.borderWidth = 0.5
    root.layer?.borderColor = NSColor.separatorColor.cgColor
    let material = NSVisualEffectView(frame: root.bounds)
    material.autoresizingMask = [.width, .height]
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    root.addSubview(material, positioned: .below, relativeTo: nil)
  }

  /// 与标题胶囊底部保留固定间隙，完整矩形夹在可用屏幕内，不创建箭头 chrome。
  func show(relativeTo anchor: NSView) {
    guard !isClosing, let owner = anchor.window else { return }
    let target = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    let screen = owner.screen?.visibleFrame ?? owner.frame
    let size = WorkspaceTitlePopoverViewController.preferredSize
    let origin = NSPoint(
      x: max(screen.minX, min(target.midX - size.width / 2, screen.maxX - size.width)),
      y: max(screen.minY, min(target.minY - 6 - size.height, screen.maxY - size.height)))
    setFrame(NSRect(origin: origin, size: size), display: false)
    ownerCloseObserver = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: owner)
      .sink { [weak self] _ in self?.close() }
    owner.addChildWindow(self, ordered: .above)
    makeKeyAndOrderFront(nil)
    menuContent.focusNameField()
  }

  override func close() {
    guard !isClosing else { return }
    isClosing = true
    ownerCloseObserver = nil
    // dismiss 的回调也会进入 close；上面的幂等保护让直接入口关闭与外部点击共用清理。
    menuContent.dismiss()
    let owner = parent
    owner?.removeChildWindow(self)
    super.close()
    if NSApp.isActive, owner?.isVisible == true { owner?.makeKey() }
    onClose?()
    onClose = nil
  }
}
