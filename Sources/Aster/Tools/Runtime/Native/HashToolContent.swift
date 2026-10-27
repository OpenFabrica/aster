// Hash 计算工具：文本直接算；输入是文件时在后台分块流式计算并显示进度，换输入或关闭即取消。
import AppKit
import AsterCore
import CryptoKit
import Darwin

/// 文件摘要计算失败的原因（读文件本身的错误按系统错误原样抛出）。
enum BuiltinFileHashError: Error {
  /// 给的是文件夹。
  case isDirectory
}

/// 文件摘要的流式计算，在并发执行器上运行，不占主线程。
enum BuiltinFileHasher {
  /// 每次读取的块大小。
  static let chunkSize = 1 << 20

  /// 文件大小；路径是目录或读不到时抛错。
  @concurrent
  static func fileSize(at url: URL) async throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
    if values.isDirectory == true { throw BuiltinFileHashError.isDirectory }
    return Int64(values.fileSize ?? 0)
  }

  /// 分块读文件，同时喂给 MD5、SHA-1、SHA-256、SHA-512；每 8 块回报一次已读字节数，块与块之间检查取消。
  /// 用 POSIX `open/read` 而不是 `FileHandle`：关闭只读描述符不会失败，也就不需要吞掉 `close()` 的错误。
  @concurrent
  static func hashes(
    ofFileAt url: URL,
    progress: @escaping @Sendable (Int64) async -> Void
  ) async throws -> [ToolResultLine] {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    var md5 = Insecure.MD5()
    var sha1 = Insecure.SHA1()
    var sha256 = SHA256()
    var sha512 = SHA512()
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var total: Int64 = 0
    var chunks = 0
    while true {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, chunkSize) }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if count == 0 { break }
      buffer.withUnsafeBytes { raw in
        let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<count])
        md5.update(bufferPointer: chunk)
        sha1.update(bufferPointer: chunk)
        sha256.update(bufferPointer: chunk)
        sha512.update(bufferPointer: chunk)
      }
      total += Int64(count)
      chunks += 1
      if chunks % 8 == 0 { await progress(total) }
    }
    return [
      ToolResultLine(label: "MD5", value: hex(md5.finalize())),
      ToolResultLine(label: "SHA-1", value: hex(sha1.finalize())),
      ToolResultLine(label: "SHA-256", value: hex(sha256.finalize())),
      ToolResultLine(label: "SHA-512", value: hex(sha512.finalize())),
    ]
  }

  /// 摘要的小写十六进制，与 `BuiltinTextTools.hashes` 的写法一致。
  private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// `hash` 内置工具的界面。
@MainActor
final class HashToolContent: BuiltinToolContent {
  /// 当前算的是输入框里的文本，还是一个文件。
  private enum Source: Equatable {
    case text
    case file(URL)
  }

  var view: NSView { root }
  var preferredHeight: CGFloat { source == .text ? 330 : 250 }
  private(set) var primaryResultText: String?

  private let actions: BuiltinToolActions
  private let root = BuiltinToolRootView()
  private let sourceLabel = makeLabel("", size: 12, weight: .medium, color: AsterTheme.ink)
  private let inputArea = BuiltinTextArea(placeholder: L("输入要计算 Hash 的文本"), editable: true)
  private let results: BuiltinResultListView
  private let status = BuiltinToolLayout.hintLabel()
  private var useTextButton: NSButton?
  private var source = Source.text
  /// 每次换输入加一；后台结果只在代次一致时回写，迟到的旧文件结果直接丢弃。
  private var generation = 0
  private var fileTask: Task<Void, Never>?
  private var fileSize: Int64 = 0
  private var isTornDown = false
  /// init 结束前不回调会话：会话此时还没拿到这个内容对象。
  private var isReady = false

  init(input: ToolInput, actions: BuiltinToolActions) {
    self.actions = actions
    results = BuiltinResultListView(labelWidth: 64) { text in actions.copy(text) }
    BuiltinToolLayout.fixHeight(inputArea, 90)
    let pick = BuiltinToolLayout.button(L("选择文件…"), symbol: "doc") { [weak self] in self?.pickFile() }
    let useText = BuiltinToolLayout.button(L("改用文本"), symbol: "text.cursor") { [weak self] in
      self?.switchToText("")
    }
    useTextButton = useText
    sourceLabel.lineBreakMode = .byTruncatingMiddle
    sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let toolbar = BuiltinToolLayout.toolbar(leading: [sourceLabel], trailing: [useText, pick])
    let card = BuiltinToolCard(content: results)
    root.install(arranged: [toolbar, inputArea, card, status], expanding: card)
    inputArea.onChange = { [weak self] _ in self?.recomputeText() }
    apply(input)
    isReady = true
  }

  func update(input: ToolInput) {
    guard !isTornDown else { return }
    apply(input)
  }

  func teardown() {
    isTornDown = true
    generation += 1
    fileTask?.cancel()
    fileTask = nil
    inputArea.onChange = nil
  }

  /// 输入里有文件就算第一个文件；有文字就算文字；两者都没有时保留用户手动选的文件。
  private func apply(_ input: ToolInput) {
    if let first = input.files.first {
      startFile(URL(fileURLWithPath: first))
    } else if let text = input.text, !text.isEmpty {
      switchToText(text)
    } else if source == .text {
      switchToText("")
    }
  }

  /// 切到文本模式并重算。
  private func switchToText(_ text: String) {
    guard !isTornDown else { return }
    let wasFile = source != .text
    source = .text
    fileTask?.cancel()
    fileTask = nil
    inputArea.string = text
    inputArea.isHidden = false
    useTextButton?.isHidden = true
    sourceLabel.stringValue = L("文本")
    recomputeText()
    if wasFile, isReady { actions.heightDidChange() }
  }

  /// 文本模式：在主线程直接算（文本最多 1 MiB，四种摘要只要几毫秒）。
  private func recomputeText() {
    guard source == .text else { return }
    generation += 1
    let text = inputArea.string
    let lines = text.isEmpty ? [] : BuiltinTextTools.hashes(of: Data(text.utf8))
    results.setLines(lines)
    BuiltinToolLayout.setHint(status, nil)
    setPrimary(lines)
  }

  /// 「选择文件…」：有窗口挂 sheet，否则模态。
  private func pickFile() {
    guard !isTornDown else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = L("计算 Hash")
    let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.startFile(url)
    }
    if let window = actions.window() {
      panel.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(panel.runModal())
    }
  }

  /// 切到文件模式：后台流式计算，按代次回写进度与结果。
  private func startFile(_ url: URL) {
    guard !isTornDown else { return }
    if source == .file(url), fileTask != nil { return }
    let wasText = source == .text
    source = .file(url)
    generation += 1
    let current = generation
    fileTask?.cancel()
    inputArea.isHidden = true
    useTextButton?.isHidden = false
    sourceLabel.stringValue = url.lastPathComponent
    sourceLabel.toolTip = url.path
    results.setLines([])
    setPrimary([])
    BuiltinToolLayout.setHint(status, L("正在计算…"))
    if wasText, isReady { actions.heightDidChange() }
    fileTask = Task { [weak self] in
      do {
        let size = try await BuiltinFileHasher.fileSize(at: url)
        self?.fileSizeKnown(size, generation: current)
        let lines = try await BuiltinFileHasher.hashes(ofFileAt: url) { [weak self] processed in
          await self?.showProgress(processed, generation: current)
        }
        self?.finishFile(.success(lines), generation: current)
      } catch {
        self?.finishFile(.failure(error), generation: current)
      }
    }
  }

  /// 文件大小就位：标题行补上大小。
  private func fileSizeKnown(_ size: Int64, generation: Int) {
    guard generation == self.generation, !isTornDown, case .file(let url) = source else { return }
    fileSize = size
    sourceLabel.stringValue = "\(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
  }

  /// 进度：已读字节占文件大小的百分比。
  private func showProgress(_ processed: Int64, generation: Int) {
    guard generation == self.generation, !isTornDown, fileSize > 0 else { return }
    let percent = Int(min(100, processed * 100 / fileSize))
    BuiltinToolLayout.setHint(status, L("正在计算…（\(String(percent))%）"))
  }

  /// 文件算完或失败；取消（换了输入、关闭）不提示。
  private func finishFile(_ result: Result<[ToolResultLine], any Error>, generation: Int) {
    guard generation == self.generation, !isTornDown else { return }
    fileTask = nil
    switch result {
    case .success(let lines):
      results.setLines(lines)
      BuiltinToolLayout.setHint(status, nil)
      setPrimary(lines)
    case .failure(let error):
      guard !(error is CancellationError) else { return }
      let message = error is BuiltinFileHashError
        ? L("不能计算文件夹的 Hash") : L("无法读取文件：\(error.localizedDescription)")
      BuiltinToolLayout.setHint(status, message, isError: true)
    }
  }

  /// 主结果取 SHA-256；变化时通知会话刷新按钮。
  private func setPrimary(_ lines: [ToolResultLine]) {
    let value = lines.first { $0.label == "SHA-256" }?.value
    guard value != primaryResultText else { return }
    primaryResultText = value
    if isReady { actions.resultDidChange() }
  }
}
