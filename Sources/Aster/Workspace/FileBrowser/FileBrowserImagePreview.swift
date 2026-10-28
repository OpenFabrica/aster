// File Browser 下半区的图片预览：选中图片时显示缩略图和尺寸信息。
// 解码放在后台按视图尺寸降采样，连续按 ↑/↓ 浏览大图也不会卡住主线程。
import AppKit
import AsterCore
import ImageIO

/// 后台解码的结果；只带 Sendable 值跨回主线程。
struct FileBrowserDecodedImage: Sendable {
  let image: CGImage
  /// 原图像素尺寸（已按 EXIF 方向转正），用于说明行。
  let pixelWidth: Int
  let pixelHeight: Int
}

/// 文件浏览器内嵌的只读图片预览。一次只显示一张；新请求会让旧的解码结果作废。
@MainActor
final class FileBrowserImagePreview: NSView {
  /// 降采样的最长边上限（像素）。足够铺满大屏 Pane，又不会把几十兆像素的原图整张解码。
  private static let maximumPixelSize: CGFloat = 4096

  private let imageView = NSImageView()
  private let captionLabel = NSTextField(labelWithString: "")
  private let messageLabel = NSTextField(labelWithString: "")
  private var loadTask: Task<Void, Never>?
  /// 每次请求加一；只有最新请求的结果才写回视图，旧结果直接丢弃。
  private var revision = 0
  /// 当前显示（或正在加载）的文件。
  private(set) var url: URL?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.paper.cgColor
    let separator = NSBox()
    separator.boxType = .separator
    imageView.imageScaling = .scaleProportionallyDown
    imageView.imageAlignment = .alignCenter
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
    captionLabel.font = NSFont.interface(ofSize: 11)
    captionLabel.textColor = AsterTheme.secondaryInk
    captionLabel.lineBreakMode = .byTruncatingMiddle
    captionLabel.alignment = .center
    captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    messageLabel.font = NSFont.interface(ofSize: 12)
    messageLabel.textColor = AsterTheme.secondaryInk
    messageLabel.alignment = .center
    messageLabel.isHidden = true
    for view in [separator, imageView, captionLabel, messageLabel] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      separator.topAnchor.constraint(equalTo: topAnchor),
      separator.leadingAnchor.constraint(equalTo: leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      captionLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
      captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      messageLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
      messageLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
      messageLabel.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  isolated deinit { loadTask?.cancel() }

  /// 是否已有可见图片；测试与状态判断用。
  var displayedImage: NSImage? { imageView.image }
  var caption: String { captionLabel.stringValue }

  /// 显示指定图片。同一文件重复调用不重新解码。
  func show(_ url: URL) {
    guard url != self.url else { return }
    self.url = url
    revision += 1
    let request = revision
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let maxPixel = min(Self.maximumPixelSize, max(bounds.width, bounds.height, 512) * scale)
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
    captionLabel.stringValue = url.lastPathComponent
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      let decoded = await Task.detached(priority: .userInitiated) {
        Self.decode(url, maxPixelSize: maxPixel)
      }.value
      guard let self, !Task.isCancelled, request == revision else { return }
      apply(decoded, url: url, fileSize: fileSize, scale: scale)
    }
  }

  /// 清空预览并作废正在进行的解码。
  func clear() {
    url = nil
    revision += 1
    loadTask?.cancel()
    loadTask = nil
    imageView.image = nil
    captionLabel.stringValue = ""
    messageLabel.isHidden = true
  }

  /// 把解码结果写回视图。NSImage 的点尺寸按屏幕倍率换算，Retina 下小图按原始清晰度显示，不被拉大。
  private func apply(_ decoded: FileBrowserDecodedImage?, url: URL, fileSize: Int?, scale: CGFloat) {
    guard let decoded else {
      imageView.image = nil
      messageLabel.stringValue = L("无法解码这张图片。")
      messageLabel.isHidden = false
      captionLabel.stringValue = url.lastPathComponent
      return
    }
    messageLabel.isHidden = true
    imageView.image = NSImage(cgImage: decoded.image, size: NSSize(
      width: CGFloat(decoded.image.width) / scale, height: CGFloat(decoded.image.height) / scale))
    var parts = [url.lastPathComponent, "\(decoded.pixelWidth) × \(decoded.pixelHeight)"]
    if let fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)) }
    captionLabel.stringValue = parts.joined(separator: "  ·  ")
  }

  /// 后台解码：用 ImageIO 直接生成降采样缩略图，并按 EXIF 方向转正。失败返回 nil。
  nonisolated static func decode(_ url: URL, maxPixelSize: CGFloat) -> FileBrowserDecodedImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width
    var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
    // EXIF 方向 5–8 表示旋转 90°，原始宽高要对调才和看到的图一致。
    if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
      swap(&width, &height)
    }
    return FileBrowserDecodedImage(image: image, pixelWidth: width, pixelHeight: height)
  }

  /// 按扩展名判断能否在文件浏览器里预览；规则与 File Pane 的图片分类一致。
  nonisolated static func canPreview(_ url: URL) -> Bool {
    FileDocumentClassifier.classify(fileName: url.lastPathComponent, prefix: Data()) == .image
  }
}
