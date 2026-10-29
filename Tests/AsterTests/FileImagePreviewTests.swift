// File Pane 图片预览：后台解码的尺寸换算，以及默认适应窗口、手动缩放与双击切换。
import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Aster

/// 在临时目录写一张纯色图片；可指定 DPI、EXIF 方向与帧数（大于 1 时写 GIF）。
private func writeImage(
  width: Int, height: Int, dpi: Double? = nil, orientation: Int? = nil, frames: Int = 1
) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-image-preview-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let type: UTType = frames > 1 ? .gif : .png
  let url = directory.appendingPathComponent(frames > 1 ? "image.gif" : "image.png")
  let context = try #require(CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
  var properties: [CFString: Any] = [:]
  if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
  if let orientation { properties[kCGImagePropertyOrientation] = orientation }
  for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
  #expect(CGImageDestinationFinalize(destination))
  return url
}

/// 把预览放进固定尺寸的窗口，等后台解码完成并完成一次布局。
@MainActor
private func loadedPreview(_ url: URL, size: NSSize) async throws -> (FileImagePreviewView, NSWindow) {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let preview = FileImagePreviewView(url: url, background: .black)
  preview.scrollView.hasVerticalScroller = false
  preview.scrollView.hasHorizontalScroller = false
  window.contentView = preview
  window.contentView?.layoutSubtreeIfNeeded()
  for _ in 0..<200 where !preview.hasImage { try await Task.sleep(for: .milliseconds(10)) }
  #expect(preview.hasImage)
  window.contentView?.layoutSubtreeIfNeeded()
  return (preview, window)
}

@Test("后台解码按 DPI 换算点尺寸，EXIF 旋转时宽高对调")
func imageDecodeUsesDPIAndOrientation() throws {
  let retina = try writeImage(width: 400, height: 200, dpi: 144)
  defer { try? FileManager.default.removeItem(at: retina.deletingLastPathComponent()) }
  let decoded = try #require(FileImageDecodeResult.decode(retina))
  #expect(decoded.pointSize == CGSize(width: 200, height: 100))
  #expect(decoded.image != nil)
  #expect(!decoded.isAnimated)

  let rotated = try writeImage(width: 300, height: 100, orientation: 6)
  defer { try? FileManager.default.removeItem(at: rotated.deletingLastPathComponent()) }
  #expect(FileImageDecodeResult.decode(rotated)?.pointSize == CGSize(width: 100, height: 300))
}

@Test("动图交给 NSImage 播放，非图片文件解码失败")
func imageDecodeHandlesAnimatedAndInvalidFiles() throws {
  let gif = try writeImage(width: 40, height: 20, frames: 3)
  defer { try? FileManager.default.removeItem(at: gif.deletingLastPathComponent()) }
  let decoded = try #require(FileImageDecodeResult.decode(gif))
  #expect(decoded.isAnimated)
  #expect(decoded.image == nil)
  #expect(decoded.pointSize == CGSize(width: 40, height: 20))

  let text = gif.deletingLastPathComponent().appendingPathComponent("not-image.png")
  try Data("hello".utf8).write(to: text)
  #expect(FileImageDecodeResult.decode(text) == nil)
}

@Test("大图默认缩小到完整可见，小图保持 100% 并居中")
@MainActor
func imagePreviewFitsLargeImagesAndCentersSmallOnes() async throws {
  let large = try writeImage(width: 2_000, height: 1_000)
  defer { try? FileManager.default.removeItem(at: large.deletingLastPathComponent()) }
  let (preview, window) = try await loadedPreview(large, size: NSSize(width: 400, height: 300))
  defer { window.close() }
  #expect(preview.isFitting)
  #expect(abs(preview.scrollView.magnification - 0.2) < 0.001)

  let small = try writeImage(width: 100, height: 50)
  defer { try? FileManager.default.removeItem(at: small.deletingLastPathComponent()) }
  let (smallPreview, smallWindow) = try await loadedPreview(small, size: NSSize(width: 400, height: 300))
  defer { smallWindow.close() }
  #expect(abs(smallPreview.scrollView.magnification - 1) < 0.001)
  // 居中：可视区比图片大，原点落在负方向上，图片位于可视区正中。
  let bounds = smallPreview.scrollView.contentView.bounds
  #expect(abs(bounds.midX - 50) < 0.5)
  #expect(abs(bounds.midY - 25) < 0.5)
}

@Test("适应窗口随 Pane 尺寸重算；手动缩放后保持所选倍率")
@MainActor
func imagePreviewRefitsUntilUserZooms() async throws {
  let url = try writeImage(width: 2_000, height: 1_000)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let (preview, window) = try await loadedPreview(url, size: NSSize(width: 400, height: 300))
  defer { window.close() }
  var reported: [Double] = []
  preview.onMagnificationChanged = { reported.append($0) }

  window.setContentSize(NSSize(width: 800, height: 600))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(abs(preview.scrollView.magnification - 0.4) < 0.001)
  #expect(reported.last.map { abs($0 - 0.4) < 0.001 } == true)

  preview.setZoom(1.5)
  #expect(!preview.isFitting)
  window.setContentSize(NSSize(width: 500, height: 400))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(abs(preview.scrollView.magnification - 1.5) < 0.001)

  preview.fitToWindow()
  #expect(preview.isFitting)
  #expect(abs(preview.scrollView.magnification - 0.25) < 0.001)
}

@Test("双击在适应窗口与 100% 之间切换")
@MainActor
func imagePreviewDoubleClickTogglesActualSize() async throws {
  let url = try writeImage(width: 2_000, height: 1_000)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let (preview, window) = try await loadedPreview(url, size: NSSize(width: 400, height: 300))
  defer { window.close() }
  var reported: [Double] = []
  preview.onMagnificationChanged = { reported.append($0) }

  preview.toggleFitAndActualSize()
  #expect(!preview.isFitting)
  #expect(abs(preview.scrollView.magnification - 1) < 0.001)
  preview.toggleFitAndActualSize()
  #expect(preview.isFitting)
  #expect(abs(preview.scrollView.magnification - 0.2) < 0.001)
  #expect(reported.count == 2)
}
