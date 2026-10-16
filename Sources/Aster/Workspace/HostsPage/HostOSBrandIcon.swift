// 发行版标志的自绘图标与品牌底色。SF Symbols 没有发行版标志，又不想为几张图引入资源打包，
// 所以用矢量路径在运行时画，任意尺寸都清晰。
import AppKit
import AsterCore

extension SSHHostOSBrand {
  /// 图标块的品牌底色（Ubuntu 橙 #E95420）。
  var tileColor: NSColor {
    switch self {
    case .ubuntu: NSColor(srgbRed: 0xE9 / 255, green: 0x54 / 255, blue: 0x20 / 255, alpha: 1)
    }
  }

  /// 白色标志图，边长 `size` 点。
  func image(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      switch self {
      case .ubuntu: Self.drawUbuntu(in: rect)
      }
      return true
    }
    image.accessibilityDescription = rawValue
    return image
  }

  /// Ubuntu「Circle of Friends」：一个圆环加三个「头」，头在 180°、60°、-60°。
  /// 先画整圆环，再在每个头周围挖一圈透明缝（`.clear` 混合），最后填头，环就断成三段。
  private static func drawUbuntu(in rect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let unit = min(rect.width, rect.height) / 2
    let ringRadius = unit * 0.52
    let headRadius = unit * 0.18
    let headDistance = unit * 0.78
    let gap = unit * 0.1
    NSColor.white.set()
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
    ring.lineWidth = unit * 0.2
    ring.stroke()
    for degrees in [180.0, 60.0, -60.0] {
      let angle = degrees * .pi / 180
      let head = CGPoint(x: center.x + cos(angle) * headDistance, y: center.y + sin(angle) * headDistance)
      context.setBlendMode(.clear)
      circle(at: head, radius: headRadius + gap).fill()
      context.setBlendMode(.normal)
      circle(at: head, radius: headRadius).fill()
    }
  }

  /// 以 `point` 为圆心的圆形路径。
  private static func circle(at point: CGPoint, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
  }
}
