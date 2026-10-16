import AppKit
import AsterCore
import Testing

@testable import Aster

// 发行版自绘标志：确认 Ubuntu 标志真的画出了头、圆环和断缝，而不是空图。

@Test("Ubuntu 标志：左侧的头和圆环不透明，圆心与断缝透明")
@MainActor
func ubuntuBrandIconDrawsCircleOfFriends() throws {
  let size = 100
  let image = SSHHostOSBrand.ubuntu.image(size: CGFloat(size))
  #expect(image.size == NSSize(width: size, height: size))
  let rep = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  // NSBitmapImageRep 的 y 轴朝下；这些点都在水平中线上，翻转不影响。
  func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
  #expect(alpha(11, 50) > 0.9)  // 左侧的头（圆心 x = 50 - 39）
  #expect(alpha(76, 50) > 0.9)  // 右侧圆环（半径 26）
  #expect(alpha(50, 50) < 0.1)  // 圆心
  #expect(alpha(24, 50) < 0.1)  // 左侧头与圆环之间的断缝
}
