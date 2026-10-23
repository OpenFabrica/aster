// agent 正在控制终端时盖在终端上的遮罩：参照 ego lite，四周一圈蓝色光晕和点阵（agent 干活时缓慢呼吸），
// 中间保持透明，用户照样看得清输出。遮罩生效时挡住点击与键盘，防止用户输入和 agent 的命令
// 交错；滚轮照常穿透，方便回看输出。用户点控制胶囊里的「接管」后遮罩撤掉。
import AppKit
import AsterCore
import QuartzCore

/// 「agent 正在控制」遮罩。由 `AgentHostTerminalContentView` 摆在终端宿主上方。
@MainActor
final class AgentHostTerminalControlOverlay: NSView {
  /// 光晕从边缘向内的宽度。
  private static let glowDepth: CGFloat = 36
  private static let glowBlue = NSColor(srgbRed: 0.30, green: 0.55, blue: 1, alpha: 1)

  /// 光晕与点阵放在单独的子视图里，呼吸动画只作用于它，不让提示文字跟着闪。
  private let glowView = NSView()
  /// 四条边的渐变光晕。
  private let glowLayers = (0..<4).map { _ in CAGradientLayer() }
  /// 点阵层，用同样的四边渐变做蒙版，只在边缘露出来。
  private let dotsLayer = CALayer()
  private let dotsMask = CALayer()
  private let dotsMaskEdges = (0..<4).map { _ in CAGradientLayer() }
  /// 顶部居中的提示胶囊：用户在遮罩上点击或按键时短暂出现，告诉他为什么没反应、怎么接管。
  /// 平时不显示，不挡终端输出。
  private let hintView = NSView()
  private let hintLabel = NSTextField(labelWithString: L("Agent 正在控制，点「接管」后可以输入"))
  /// 遮罩是否生效（拦截输入）。淡出动画期间已为 false。
  private(set) var isActive = false
  /// agent 是否正在干活（连接中、命令运行中）。只有这时光晕才呼吸；空闲、等输入时遮罩一直盖着，
  /// 光晕保持静止，不暗示「正在跑」，也不让动画在空闲终端上一直耗电。
  var isBreathing = false {
    didSet { if isBreathing != oldValue { updateBreathing() } }
  }
  /// 呼吸动画是否在跑；测试用。
  var hasBreathingAnimation: Bool { glowView.layer?.animation(forKey: "breathing") != nil }
  /// 提示的自动隐藏任务；再次触发时重新计时。
  private var hintHideTask: Task<Void, Never>?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    alphaValue = 0
    isHidden = true
    glowView.wantsLayer = true
    addSubview(glowView)
    for glow in glowLayers {
      glow.colors = [Self.glowBlue.withAlphaComponent(0.55).cgColor, Self.glowBlue.withAlphaComponent(0).cgColor]
      glowView.layer?.addSublayer(glow)
    }
    dotsLayer.backgroundColor = NSColor(patternImage: Self.dotPattern()).cgColor
    for edge in dotsMaskEdges {
      edge.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
      dotsMask.addSublayer(edge)
    }
    dotsLayer.mask = dotsMask
    glowView.layer?.addSublayer(dotsLayer)

    hintView.appearance = NSAppearance(named: .darkAqua)
    hintView.wantsLayer = true
    hintView.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.9).cgColor
    hintView.layer?.cornerRadius = 13
    hintLabel.font = .systemFont(ofSize: 12, weight: .medium)
    hintLabel.textColor = NSColor(white: 1, alpha: 0.85)
    hintLabel.lineBreakMode = .byTruncatingTail
    hintView.addSubview(hintLabel)
    hintView.alphaValue = 0
    addSubview(hintView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 生效时接住点击、拖动和右键，让它们到不了终端；滚轮放行给下面的终端回看输出。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isActive, NSApp?.currentEvent?.type != .scrollWheel else { return nil }
    return super.hitTest(point) == nil ? nil : self
  }

  /// 生效时由容器把键盘焦点移到遮罩上，按键在这里被吞掉。
  override var acceptsFirstResponder: Bool { isActive }

  override func keyDown(with event: NSEvent) { flashHint() }
  override func mouseDown(with event: NSEvent) { flashHint() }
  override func rightMouseDown(with event: NSEvent) { flashHint() }
  override func otherMouseDown(with event: NSEvent) { flashHint() }

  /// 生效时用箭头光标，不显示终端的 I 形光标，免得用户以为能选字。
  override func resetCursorRects() {
    if isActive { addCursorRect(bounds, cursor: .arrow) }
  }

  /// 显示或隐藏遮罩，带淡入淡出；显示时若 agent 正在干活就开始呼吸动画，撤掉时立即停下。
  func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    window?.invalidateCursorRects(for: self)
    if active { isHidden = false }
    updateBreathing()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      animator().alphaValue = active ? 1 : 0
    } completionHandler: { [weak self] in
      // 淡出过程中又被激活时不能隐藏。
      MainActor.assumeIsolated {
        guard let self, !self.isActive else { return }
        self.isHidden = true
        self.hintHideTask?.cancel()
        self.hintView.alphaValue = 0
        self.glowView.layer?.removeAnimation(forKey: "settle")
      }
    }
  }

  override func layout() {
    super.layout()
    glowView.frame = bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    Self.layoutEdges(glowLayers, in: bounds)
    dotsLayer.frame = bounds
    dotsMask.frame = bounds
    Self.layoutEdges(dotsMaskEdges, in: bounds)
    CATransaction.commit()
    // 提示胶囊贴顶居中（底部留给控制胶囊），窄窗口时两侧各留 12pt 并截断文字。
    let labelSize = hintLabel.intrinsicContentSize
    // 多留 4pt：intrinsicContentSize 取整后正好等宽时 AppKit 仍会截断末尾。
    let hintWidth = min(ceil(labelSize.width) + 32, max(bounds.width - 24, 0))
    hintView.frame = NSRect(
      x: ((bounds.width - hintWidth) / 2).rounded(), y: bounds.height - 40, width: hintWidth, height: 26)
    hintLabel.frame = NSRect(
      x: 14, y: ((26 - labelSize.height) / 2).rounded(), width: max(hintWidth - 28, 0), height: labelSize.height)
  }

  /// 淡入提示，2.5 秒后淡出；连续点击只重新计时。
  private func flashHint() {
    guard isActive else { return }
    hintHideTask?.cancel()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      hintView.animator().alphaValue = 1
    }
    hintHideTask = Task { @MainActor [weak self] in
      // 被取消（又一次点击或遮罩撤掉）时 sleep 抛错，直接结束，由新的计时或撤掉逻辑接管。
      do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
      guard let self else { return }
      NSAnimationContext.runAnimationGroup(
        { context in
          context.duration = 0.3
          self.hintView.animator().alphaValue = 0
        }, completionHandler: nil)
    }
  }

  // MARK: - 私有

  /// 四条渐变依次贴下、上、左、右边，颜色从边缘（startPoint）向内淡出。
  private static func layoutEdges(_ edges: [CAGradientLayer], in bounds: NSRect) {
    let depth = min(glowDepth, bounds.width / 2, bounds.height / 2)
    let frames = [
      NSRect(x: 0, y: 0, width: bounds.width, height: depth),
      NSRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth),
      NSRect(x: 0, y: 0, width: depth, height: bounds.height),
      NSRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height),
    ]
    // CALayer 坐标在 layer-backed NSView 里与视图一致（原点左下），y=0 是下边。
    let directions: [(CGPoint, CGPoint)] = [
      (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
      (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
      (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
      (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
    ]
    for (index, edge) in edges.enumerated() {
      edge.frame = frames[index]
      edge.startPoint = directions[index].0
      edge.endPoint = directions[index].1
    }
  }

  /// 遮罩生效且 agent 在干活时呼吸，否则停下。
  private func updateBreathing() {
    if isActive && isBreathing { startBreathing() } else { stopBreathing() }
  }

  /// 停止呼吸：从当前亮度平滑回到常亮，避免命令一结束光晕跳一下。
  private func stopBreathing() {
    guard let layer = glowView.layer, layer.animation(forKey: "breathing") != nil else { return }
    let current = layer.presentation()?.opacity ?? 1
    layer.removeAnimation(forKey: "breathing")
    let settle = CABasicAnimation(keyPath: "opacity")
    settle.fromValue = current
    settle.toValue = 1
    settle.duration = 0.3
    layer.add(settle, forKey: "settle")
  }

  /// 不透明度在 0.75 与 1 之间缓慢往返，避免呼吸低点过淡；系统开了「减少动态效果」时保持静止。
  private func startBreathing() {
    guard let layer = glowView.layer, layer.animation(forKey: "breathing") == nil,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else { return }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1
    animation.toValue = 0.75
    animation.duration = 1.6
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(animation, forKey: "breathing")
  }

  /// 6pt 一格、中心一个 1.2pt 蓝点的平铺图案。
  private static func dotPattern() -> NSImage {
    NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
      glowBlue.withAlphaComponent(0.7).setFill()
      NSBezierPath(ovalIn: NSRect(x: rect.midX - 0.6, y: rect.midY - 0.6, width: 1.2, height: 1.2)).fill()
      return true
    }
  }
}
