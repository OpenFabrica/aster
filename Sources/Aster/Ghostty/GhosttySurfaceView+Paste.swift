// Ghostty 终端的粘贴入口：普通粘贴、Paste As 变体与粘贴保护。
// 剪贴板内容的取舍顺序与放行规则对齐 Otty，见 docs/developer/terminal-domain.md。
import AppKit
import AsterCore
@preconcurrency import GhosttyKit

extension GhosttySurfaceView {
  // MARK: - Paste delivery

  /// 当前是否允许把粘贴内容写进前台程序：只读、受管闸门关闭、Pane 导航模式都会拒绝。
  var acceptsPaste: Bool {
    surface != nil && isProcessRunning && !readOnly && managedInputGateOpen
      && navigationMode == .normal
  }

  /// 用户粘贴走 libghostty 的 `surface_text`，由内核按目标的 bracketed-paste 模式
  /// 自动包裹。Aster 先按当前屏幕、bracketed paste 与 OSC 133 命令状态做风险确认，
  /// 控制字符永远不会静默放行。末尾回车先被去掉，粘贴只填入输入行。
  @discardableResult
  func pasteText(_ text: String) -> Bool {
    let text = TerminalClipboardText.trimmingTrailingNewlines(in: text)
    guard acceptsPaste, !text.isEmpty else { return false }
    guard confirmPasteIfNeeded(text, forceBracketed: false) else { return false }
    deliverPasteText(text)
    return true
  }

  /// 不经风险确认投递 Aster 自己生成的文本（Shell 转义后的路径或单引号包裹的正文）。
  /// 这类文本不含裸换行，无法在粘贴瞬间执行命令，与 Otty 的处理一致。
  @discardableResult
  func pasteGeneratedText(_ text: String) -> Bool {
    guard acceptsPaste, !text.isEmpty else { return false }
    deliverPasteText(text)
    return true
  }

  /// 无论程序是否开启 DECSET 2004 都按括号粘贴投递。程序已开启时交给 libghostty 包裹；
  /// 未开启时 Aster 自行编码，正文中的结束标记会被替换，不能提前结束粘贴块。
  @discardableResult
  func pasteTextForcingBracketed(_ text: String) -> Bool {
    let text = TerminalClipboardText.trimmingTrailingNewlines(in: text)
    guard acceptsPaste, !text.isEmpty else { return false }
    guard confirmPasteIfNeeded(text, forceBracketed: true) else { return false }
    if bufferInfo()?.bracketed_paste == true {
      deliverPasteText(text)
      return true
    }
    onUserInput?()
    return sendProtocolBytes(PasteTransmissionEncoder.encode(text, bracketed: true))
  }

  private func deliverPasteText(_ text: String) {
    guard let surface else { return }
    onUserInput?()
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
  }

  /// 有风险时弹框确认。`forceBracketed` 表示这次一定以括号粘贴投递，即使程序未开启该模式。
  private func confirmPasteIfNeeded(_ text: String, forceBracketed: Bool) -> Bool {
    let info = bufferInfo()
    let analysis = PasteRiskAnalyzer.analyze(text)
    guard
      PasteProtectionPolicy.requiresConfirmation(
        for: analysis,
        protectionEnabled: pasteProtectionEnabled,
        isAlternateScreen: info?.alternate_screen ?? false,
        isBracketedPasteMode: forceBracketed || info?.bracketed_paste == true,
        treatsBracketedPasteAsSafe: pasteBracketedSafe,
        isCommandRunning: isShellCommandRunning?() ?? false
      )
    else { return true }
    return Self.presentPasteConfirmation(analysis)
  }

  // MARK: - Pasteboard actions

  /// 普通粘贴按 Otty 的顺序取剪贴板：文件 → 文本 → 图片。文件粘贴为转义后的路径；
  /// 只有图片时先存成本地临时文件再粘贴路径。远端受管终端的图片仍走上传流程。
  @objc func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if let handler = onRemoteImagePaste,
      RemoteImageUploader.pasteboardHasImage(pasteboard),
      let imageData = RemoteImageUploader.extractImageData(from: pasteboard)
    {
      Task { @MainActor [weak self] in
        guard let self else { return }
        // 成功时粘贴远端路径（不带换行）；取消或失败都不粘贴，避免残留。
        if case .success(let remotePath) = await handler(imageData) {
          _ = self.pasteText(remotePath)
        }
      }
      return
    }
    // 本地文件路径和临时图片只对本机 Shell 有意义；远端受管终端退回粘贴文本。
    let pastesLocalFiles = onRemoteImagePaste == nil
    if pastesLocalFiles, let paths = Self.escapedFilePaths(from: pasteboard) {
      _ = pasteGeneratedText(paths)
      return
    }
    if let text = pasteboard.string(forType: .string), !text.isEmpty {
      _ = pasteText(text)
      return
    }
    if pastesLocalFiles, let imageData = RemoteImageUploader.extractImageData(from: pasteboard) {
      pasteLocalImage(imageData)
    }
  }

  @objc func pasteBracketed(_ sender: Any?) {
    guard let text = readSystemClipboard(), !text.isEmpty else { return NSSound.beep() }
    _ = pasteTextForcingBracketed(text)
  }

  /// 粘贴当前终端选区，仍经过粘贴保护。
  @objc func pasteSelection(_ sender: Any?) {
    guard let text = readSelection(), !text.isEmpty else { return NSSound.beep() }
    _ = pasteText(text)
  }

  /// 文件粘贴为转义路径，文本整体用单引号包裹成一个 Shell 参数。
  @objc func pasteEscapingSpecialCharacters(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if let paths = Self.escapedFilePaths(from: pasteboard) {
      _ = pasteGeneratedText(paths)
    } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
      _ = pasteGeneratedText(ShellPasteEscaper.escape(text))
    } else {
      NSSound.beep()
    }
  }

  @objc func pasteAndContinueInComposer(_ sender: Any?) {
    guard let text = readSystemClipboard() else { return }
    onPasteIntoComposer?(text)
  }

  /// 剪贴板里有可粘贴的文本、文件或图片时返回 true，供菜单校验使用。
  static func pasteboardHasPastableContent(_ pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.string(forType: .string) != nil
      || pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLReadingOptions)
      || RemoteImageUploader.pasteboardHasImage(pasteboard)
  }

  static func pasteboardHasEscapableContent(_ pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.string(forType: .string) != nil
      || pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLReadingOptions)
  }

  // MARK: - Helpers

  private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
    .urlReadingFileURLsOnly: true
  ]

  /// Finder 复制的文件会同时带文件 URL 和文件名文本；文件 URL 优先，否则只会粘出文件名。
  private static func escapedFilePaths(from pasteboard: NSPasteboard) -> String? {
    let urls =
      pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLReadingOptions) as? [URL]
    return ShellPasteEscaper.escapePaths((urls ?? []).map(\.path))
  }

  /// 把剪贴板图片存成 `0600` 临时 PNG，再粘贴其转义路径；写入失败时提示音反馈。
  private func pasteLocalImage(_ data: Data) {
    do {
      let url = try TerminalImportedFileStore.save(data, type: .png)
      _ = pasteGeneratedText(ShellPasteEscaper.escape(url.path))
    } catch {
      NSSound.beep()
    }
  }

  private static func presentPasteConfirmation(_ analysis: PasteAnalysis) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("粘贴的内容可能立即执行命令")
    let reasons = analysis.risks.map { risk -> String in
      switch risk {
      case .multipleLines: L("包含多行")
      case .trailingNewline: L("末尾包含换行")
      case .privilegeEscalation: L("包含 sudo 或 su")
      case .controlCharacters: L("包含不可见控制字符")
      }
    }.sorted().joined(separator: "、")
    alert.informativeText = L("检测到：\(reasons)\n\n\(analysis.preview())")
    alert.addButton(withTitle: L("仍然粘贴"))
    alert.addButton(withTitle: L("取消"))
    return alert.runModal() == .alertFirstButtonReturn
  }
}
