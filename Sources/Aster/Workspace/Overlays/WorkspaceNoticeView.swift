// 工作区状态提示：动态文字与 CALayer 底色始终按同一有效外观解析。
import AppKit

@MainActor
final class WorkspaceNoticeView: NSTextField {
  init(message: String) {
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    stringValue = message
    font = .interface(ofSize: 11, weight: .medium)
    textColor = AsterTheme.ink
    lineBreakMode = .byTruncatingTail
    alignment = .center
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    applyLayerColors()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyLayerColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyLayerColors()
  }

  private func applyLayerColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.95).cgColor
      layer?.borderColor = AsterTheme.hairline.cgColor
    }
  }
}
