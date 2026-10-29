// File Pane 的图片预览：默认适应窗口（大图缩小、小图保持原尺寸）、居中、按住拖动平移、
// 双击在「适应窗口」与 100% 之间切换。静态图在后台用 ImageIO 解码，主线程只接收 CGImage；
// 动图仍交给 NSImage 播放。
import AppKit
import AsterCore
import ImageIO

/// 后台解码的结果；只带 Sendable 值跨回主线程。
struct FileImageDecodeResult: Sendable {
  /// 已解码的静态图；动图为 nil，由主线程用 NSImage 加载以保留播放。
  let image: CGImage?
  /// 100% 时的显示尺寸（点），按 DPI 与 EXIF 方向换算自原图，不受降采样影响。
  let pointSize: CGSize
  let isAnimated: Bool

  /// 解码时的最长边上限（像素）。超过时降采样，100% 显示仍按原图点尺寸铺开。
  static let maximumDecodedPixels = 8_192

  /// 在后台读取并解码图片。无法读取时返回 nil。
  nonisolated static func decode(_ url: URL) -> FileImageDecodeResult? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    // EXIF 方向 5–8 表示旋转 90°，原始宽高要对调才和看到的图一致。
    if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
      swap(&width, &height)
    }
    // 与 NSImage 一致按 DPI 换算点尺寸：144 DPI 的截图在 100% 下不会被放大一倍。
    let dpiX = (properties?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
    let dpiY = (properties?[kCGImagePropertyDPIHeight] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
    if CGImageSourceGetCount(source) > 1 {
      let size = CGSize(width: Double(width) * 72 / dpiX, height: Double(height) * 72 / dpiY)
      return FileImageDecodeResult(image: nil, pointSize: size, isAnimated: true)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(maximumDecodedPixels, max(width, height, 1)),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    if width == 0 || height == 0 { (width, height) = (image.width, image.height) }
    let size = CGSize(width: Double(width) * 72 / dpiX, height: Double(height) * 72 / dpiY)
    return FileImageDecodeResult(image: image, pointSize: size, isAnimated: false)
  }
}

/// 文档比可视区小时居中显示，而不是贴在左下角。
@MainActor
final class FileImageCenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let document = documentView else { return rect }
    if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
    if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
    return rect
  }
}

/// 图片预览容器：持有滚动视图与图片视图，管理「适应窗口」状态与倍率。
@MainActor
final class FileImagePreviewView: NSView {
  let scrollView = NSScrollView()
  let imageView = FilePreviewImageView()
  /// 倍率变化（适应窗口重算、触控板捏合、双击切换）时通知工具条更新显示，不回写倍率。
  var onMagnificationChanged: ((Double) -> Void)?
  /// 为 true 时 Pane 尺寸变化会重新适应；用户手动缩放后变为 false，保持所选倍率。
  private(set) var isFitting = true
  /// 解码完成后的 100% 显示尺寸；解码前为零。
  private(set) var imagePointSize: CGSize = .zero
  private let messageLabel = NSTextField(labelWithString: "")
  private var loadTask: Task<Void, Never>?
  private var magnifyObserver: NSObjectProtocol?

  init(url: URL, background: NSColor) {
    super.init(frame: .zero)
    scrollView.contentView = FileImageCenteringClipView()
    scrollView.drawsBackground = true
    scrollView.backgroundColor = background
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.1
    scrollView.maxMagnification = 16
    scrollView.documentView = imageView
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.animates = true
    imageView.onDoubleClick = { [weak self] in self?.toggleFitAndActualSize() }
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.alignment = .center
    messageLabel.isHidden = true
    for view in [scrollView, messageLabel] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    scrollView.pinEdges(to: self)
    NSLayoutConstraint.activate([
      messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      messageLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
    ])
    // 触控板捏合是用户手动缩放：此后不再随 Pane 尺寸自动适应，并让工具条显示新倍率。
    magnifyObserver = NotificationCenter.default.addObserver(
      forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isFitting = false
        self.onMagnificationChanged?(Double(self.scrollView.magnification))
      }
    }
    load(url)
  }

  required init?(coder: NSCoder) { nil }

  isolated deinit {
    loadTask?.cancel()
    if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
  }

  /// 当前是否已有可显示的图片；测试与状态判断用。
  var hasImage: Bool { imageView.image != nil }

  /// 「适应窗口」对应的倍率：大图缩小到完整可见，小图不放大（最多 100%）。
  var fitMagnification: CGFloat {
    let viewport = scrollView.contentView.frame.size
    guard imagePointSize.width > 0, imagePointSize.height > 0,
      viewport.width > 0, viewport.height > 0
    else { return 1 }
    let fit = min(viewport.width / imagePointSize.width, viewport.height / imagePointSize.height)
    return max(scrollView.minMagnification, min(1, fit))
  }

  override func layout() {
    super.layout()
    if isFitting { applyFit() }
  }

  /// 回到适应窗口状态（工具条「适应窗口」、双击）。
  func fitToWindow() {
    isFitting = true
    applyFit()
  }

  /// 工具条选择的倍率：属于手动缩放，以可视区中心为基准。
  func setZoom(_ zoom: Double) {
    isFitting = false
    setMagnificationCentered(CGFloat(zoom))
  }

  /// 更新背景色（主题切换）。
  func setBackground(_ color: NSColor) {
    scrollView.backgroundColor = color
  }

  /// 双击：当前是适应窗口就切到 100%，否则回到适应窗口。
  func toggleFitAndActualSize() {
    if isFitting, abs(scrollView.magnification - 1) > 0.001 {
      isFitting = false
      setMagnificationCentered(1)
      onMagnificationChanged?(Double(scrollView.magnification))
    } else {
      // 回到适应窗口；倍率有变化时由 applyFit 通知，不重复上报。
      fitToWindow()
    }
  }

  /// 按当前可视区重算适应倍率；倍率真的变了才通知工具条，避免布局期间反复刷新。
  private func applyFit() {
    guard imagePointSize != .zero else { return }
    let target = fitMagnification
    guard abs(scrollView.magnification - target) > 0.0001 else { return }
    setMagnificationCentered(target)
    onMagnificationChanged?(Double(target))
  }

  private func setMagnificationCentered(_ magnification: CGFloat) {
    let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, magnification))
    let visible = scrollView.contentView.bounds
    scrollView.setMagnification(clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    // 倍率决定图片能否拖动，光标区域要随之更新。
    window?.invalidateCursorRects(for: imageView)
  }

  /// 后台解码；完成后按原图点尺寸设置文档大小并适应窗口。
  private func load(_ url: URL) {
    loadTask = Task { [weak self] in
      let decoded = await Task.detached(priority: .userInitiated) {
        FileImageDecodeResult.decode(url)
      }.value
      guard let self, !Task.isCancelled else { return }
      self.apply(decoded, url: url)
    }
  }

  private func apply(_ decoded: FileImageDecodeResult?, url: URL) {
    let image: NSImage?
    if let decoded, let cgImage = decoded.image {
      image = NSImage(cgImage: cgImage, size: decoded.pointSize)
    } else if decoded?.isAnimated == true {
      // 动图需要 NSImage 的逐帧播放；NSImage 按需解码，这里不会整段读进内存。
      image = NSImage(contentsOf: url)
    } else {
      image = nil
    }
    guard let image, image.size.width > 0, image.size.height > 0 else {
      messageLabel.stringValue = L("无法解码这张图片。")
      messageLabel.isHidden = false
      return
    }
    imagePointSize = decoded?.pointSize ?? image.size
    imageView.image = image
    imageView.frame = NSRect(origin: .zero, size: imagePointSize)
    isFitting = true
    layoutSubtreeIfNeeded()
    applyFit()
    onMagnificationChanged?(Double(scrollView.magnification))
  }
}
