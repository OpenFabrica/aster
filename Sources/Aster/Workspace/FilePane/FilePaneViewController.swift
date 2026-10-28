import AppKit
import AsterCore
import Combine
import PDFKit
import Quartz
import WebKit

/// 统一承载可编辑源文件和只读富预览的 Pane。持久化层仍只区分 `.editor` / `.preview`；
/// Source/Preview、锁定、语言和缩放均为当前 Pane 的运行态，不污染工作区快照。
@MainActor
final class FilePaneViewController: NSViewController, WKNavigationDelegate {
  private static let classificationPrefixBytes = 64 * 1_024
  private static let boundedPreviewBytes = 4 * 1_024 * 1_024

  private let runtime: WorkspacePaneRuntime
  private weak var tab: TerminalTabItem?
  private let model: AppModel
  private let preferences: AppPreferences
  private let renderer: any FileRendering
  private let contentHost = NSView()
  /// 工具条与内容区所在的纵向容器；查找栏按需插在两者之间。
  private weak var column: NSStackView?
  private var findBar: FilePaneFindBar?
  private let modeControl = FilePresentationControl(
    labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
  private var presentationKind: FilePresentationKind = .sourceText
  private var showingPreview = false
  private var observedDirty: Bool
  private var observedReadOnly: Bool
  private var observedDocumentError: String?
  private var softWrap: Bool
  private var selectedLanguage: String?
  private var syntaxLanguages: [String] = []
  private var cancellables: Set<AnyCancellable> = []
  private var documentDelegate: DocumentTextDelegate?
  private var sourceScrollView: NSScrollView?
  private var renderedTheme: TerminalTheme?
  private var renderedFont: NSFont?
  private var cachedPreviewView: NSView?
  private weak var transcriptWebView: WKWebView?
  private var transcriptBody: String?
  private weak var toolbarView: FilePaneToolbar?
  private var contentZoom: Double = 1
  private(set) weak var previewWebView: WKWebView?
  private var sourceRenderRevision = 0
  private var previewRenderRevision = 0
  private var renderedPreviewText: String?
  private var pendingPreviewBody: String?
  /// JSON 的最近一次解析结果；树视图首次创建时直接使用，不必再等一轮渲染。
  private var pendingJSONResult: Result<JSONNode, JSONParseError>?
  private weak var jsonTreeView: FileJSONTreeView?
  private var sourceRenderTask: Task<Void, Never>?
  private var previewRenderTask: Task<Void, Never>?
  /// 监听目标文件的父目录可同时覆盖原位写入与 atomic replace；事件合并后仍由 mtime
  /// 判重。只有 vnode 监听无法建立时才使用兼容 timer，保证外部修改检测不失效。
  private var modificationWatcher: FileSystemDirectoryWatcher?
  private nonisolated(unsafe) var modificationFallbackTimer: Timer?
  private var lastModificationDate: Date?
  private var reportedExternalConflict = false
  private weak var statusSpinner: NSProgressIndicator?
  private(set) weak var sourceTextView: NSTextView?
  /// Workspace 控制器用它维护行跳转目标；锁定或切换 Source/Preview 会替换 NSTextView，
  /// 因此不能只在首次建 Pane 时登记一次。
  var onSourceTextViewChanged: ((NSTextView?) -> Void)?

  init(
    runtime: WorkspacePaneRuntime,
    tab: TerminalTabItem,
    model: AppModel,
    preferences: AppPreferences,
    renderer: any FileRendering = FileRenderPipeline()
  ) {
    self.runtime = runtime
    self.tab = tab
    self.model = model
    self.preferences = preferences
    self.renderer = renderer
    self.softWrap = preferences.configuration.editor.lineWrap
    self.observedDirty = runtime.isDirty
    self.observedReadOnly = runtime.isReadOnly
    self.observedDocumentError = runtime.documentError
    super.init(nibName: nil, bundle: nil)
    classifyDocument()
    showingPreview = initiallyShowsPreview
  }

  required init?(coder: NSCoder) { nil }

  /// 打开时是否直接显示预览。图片、PDF、富文档和二进制没有文本内容（runtime 不加载
  /// `documentText`），即使以 Editor 打开也只能走预览，否则源码视图只剩一个空的行号 1。
  private var initiallyShowsPreview: Bool {
    guard presentationKind.usesTextContent else { return true }
    return runtime.descriptor.kind == .preview && presentationKind != .sourceText
  }

  override func loadView() {
    let root = AppearanceObservingView()
    // 源码高亮颜色是渲染时按外观固定下来的，外观切换后要按新主题重新着色。
    root.onEffectiveAppearanceChange = { [weak self] in self?.synchronizeEditorPresentation() }
    let column = NSStackView(views: [makeToolbar(), contentHost])
    column.orientation = .vertical
    // 纵向 NSStackView 默认 centerX 对齐：内容视图一旦有固有宽度（如 transcript
    // 页头的 label），就会被按 fitting 宽度居中而不是撑满 Pane。显式 .width 让
    // 工具条与内容区始终跟随 Pane 宽度（规则 5：容器两个方向都要有确定尺寸）。
    column.alignment = .width
    column.spacing = 0
    self.column = column
    root.addSubview(column)
    column.pinEdges(to: root)
    view = root
    renderContent()
    observeRuntime()
    startModificationMonitoring()
    Task { [weak self, renderer] in
      let languages = await renderer.sourceLanguages()
      self?.syntaxLanguages = languages
    }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateSourceLayout()
  }

  deinit {
    modificationFallbackTimer?.invalidate()
    sourceRenderTask?.cancel()
    previewRenderTask?.cancel()
  }

  private var fileURL: URL? {
    runtime.descriptor.resourcePath.map { URL(fileURLWithPath: $0) }
  }

  private func classifyDocument() {
    guard let fileURL else { return }
    let prefix = readPrefix(of: fileURL, maximumBytes: Self.classificationPrefixBytes)
    let trustedProvider = model.agentHistories.first(where: {
      $0.metadata.transcriptFileURL.standardizedFileURL == fileURL.standardizedFileURL
    })?.metadata.configuration.provider
    presentationKind = FileDocumentClassifier.classify(
      fileName: fileURL.lastPathComponent,
      prefix: prefix,
      trustedAgentProvider: trustedProvider
    )
  }

  /// 文件名由外层 Pane 标题展示；工具条只承载当前文件的呈现和动作。
  private func makeToolbar() -> NSView {
    modeControl.identifier = .init("file-pane-presentation")
    modeControl.target = self
    modeControl.action = #selector(changePresentationMode)
    modeControl.setAccessibilityLabel("File presentation")
    configureModeControl()
    let bar = FilePaneToolbar(mode: modeControl,
      send: { [weak self] in self?.sendCurrentContentToChat() },
      open: { [weak self] in self?.showFileActions() },
      save: { [weak self] in self?.save() },
      discard: { [weak self] in self?.reloadFromDisk() },
      run: { [weak self] in self?.runShellFile() },
      resume: { [weak self] in self?.resumeHistory() },
      format: { [weak self] in self?.formatJSON(minify: false) },
      close: { [weak self] in
        guard let self, let tab, tab.runtime(for: runtime.id) === runtime else { return }
        model.select(tab)
        tab.setActivePane(runtime.id)
        model.closeSelectedPaneOrTab()
      })
    toolbarView = bar
    statusSpinner = bar.spinner
    bar.onZoom = { [weak self] zoom in self?.setContentZoom(zoom) }
    bar.onZoomToFit = { [weak self] in self?.zoomToFit() }
    let theme = preferences.activeTheme
    bar.layer?.backgroundColor = NSColor(theme.resolvedColor(forSlot: "container.background")
      ?? theme.style.container.background ?? theme.palette.containerBackground).cgColor
    updateToolbar()
    return bar
  }

  private func observeRuntime() {
    preferences.objectWillChange.sink { [weak self] _ in
      // @Published 的 willSet 通知还不能回读新配置；下一轮统一同步主题与编辑器设置。
      DispatchQueue.main.async { [weak self] in self?.synchronizeEditorPresentation() }
    }.store(in: &cancellables)
    runtime.$documentText.dropFirst().sink { [weak self] text in
      guard let self else { return }
      // 使用 @Published 发出的新值；在 willSet 通知期间回读 runtime 属性可能仍是旧文本，
      // 会把用户刚输入的字符错误覆盖回去。
      if sourceTextView?.string != text {
        sourceTextView?.string = text
      }
      scheduleSourceRendering()
      schedulePreviewRendering(text: text)
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$isDirty.sink { [weak self] isDirty in
      guard let self else { return }
      observedDirty = isDirty
      if !isDirty {
        lastModificationDate = modificationDate()
        reportedExternalConflict = false
      }
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$isReadOnly.sink { [weak self] isReadOnly in
      guard let self else { return }
      observedReadOnly = isReadOnly
      sourceTextView?.isEditable = presentationKind.supportsEditing && !isReadOnly
      updateToolbar()
    }.store(in: &cancellables)
    runtime.$documentError.sink { [weak self] error in
      self?.observedDocumentError = error
      self?.updateToolbar()
    }.store(in: &cancellables)
    model.fileFindRequested.sink { [weak self] request in
      guard let self, request.paneID == runtime.id else { return }
      toggleFindBar(forceVisible: !request.toggle)
    }.store(in: &cancellables)
    model.agentHistoriesChanged.sink { [weak self] _ in
      guard let self else { return }
      let previous = presentationKind
      classifyDocument()
      guard presentationKind != previous else { return }
      showingPreview = initiallyShowsPreview
      cachedPreviewView = nil
      previewWebView = nil
      renderedPreviewText = nil
      pendingPreviewBody = nil
      pendingJSONResult = nil
      jsonTreeView = nil
      configureModeControl()
      renderContent()
    }.store(in: &cancellables)
  }

  private func updateToolbar() {
    let status: String?
    if let error = observedDocumentError { status = error }
    else if reportedExternalConflict { status = L("磁盘文件已修改") }
    else { status = nil }
    toolbarView?.update(editable: presentationKind.supportsEditing && !observedReadOnly && !showingPreview,
      dirty: observedDirty, statusText: status)
    toolbarView?.showZoom(showingPreview && [.svg, .image].contains(presentationKind))
    toolbarView?.runButton.isHidden = fileURL?.pathExtension.lowercased() != "sh" || !model.isLocalMachineActive
    toolbarView?.resumeButton.isHidden = presentationKind != .agentTranscript || !showingPreview
    toolbarView?.formatButton.isHidden = presentationKind != .json || showingPreview || observedReadOnly
    configureModeControl()
  }

  @objc private func changePresentationMode() {
    if presentationKind.supportsSourcePreviewToggle {
      showingPreview = modeControl.selectedSegment == 1
    } else if presentationKind.supportsEditing {
      runtime.setReadOnly(modeControl.selectedSegment == 1)
    }
    if !showingPreview { statusSpinner?.stopAnimation(nil) }
    updateToolbar()
    renderContent()
  }

  /// Markdown 等双形态文本使用 code/eye，JSON 使用 code/树；普通源码使用 code/lock。
  /// 预览专用类型不显示无效开关，避免 transcript、图片或 PDF 出现点了也不能编辑的控件。
  private func configureModeControl() {
    let canPreview = presentationKind.supportsSourcePreviewToggle
    let previewSymbol = presentationKind == .json ? "list.bullet.indent" : "eye"
    let previewName = presentationKind == .json ? "Tree" : "Preview"
    modeControl.isHidden = !canPreview && !presentationKind.supportsEditing
    modeControl.setImage(
      NSImage(
        systemSymbolName: canPreview ? "chevron.left.forwardslash.chevron.right" : "square.and.pencil",
        accessibilityDescription: "Source"
      ),
      forSegment: 0
    )
    modeControl.setImage(
      NSImage(
        systemSymbolName: canPreview ? previewSymbol : "lock.fill",
        accessibilityDescription: canPreview ? previewName : "Lock editing"
      ),
      forSegment: 1
    )
    modeControl.setToolTip("Source", forSegment: 0)
    modeControl.setToolTip(canPreview ? previewName : "Lock editing", forSegment: 1)
    modeControl.selectedSegment =
      canPreview ? (showingPreview ? 1 : 0) : (observedReadOnly ? 1 : 0)
  }

  /// ⌘F 的文件 Pane 版本：显示查找栏并聚焦输入框；已显示时再按一次关闭。
  /// `forceVisible` 用于命令面板等「只打开不关闭」的入口。
  private func toggleFindBar(forceVisible: Bool) {
    if let findBar {
      guard forceVisible else { return closeFindBar() }
      findBar.focusField()
      return
    }
    guard FilePaneFindTarget.resolve(in: contentHost) != nil, let column else {
      model.notice = L("此文件类型不支持查找")
      return
    }
    let bar = FilePaneFindBar(
      resolveTarget: { [weak self] in
        guard let self else { return nil }
        return FilePaneFindTarget.resolve(in: contentHost)
      },
      onClose: { [weak self] in self?.closeFindBar() }
    )
    column.insertArrangedSubview(bar, at: 1)
    findBar = bar
    bar.focusField()
  }

  /// 关闭查找栏，并把焦点还给源码视图，方便接着编辑找到的位置。
  private func closeFindBar() {
    findBar?.removeFromSuperview()
    findBar = nil
    if !showingPreview, let sourceTextView { view.window?.makeFirstResponder(sourceTextView) }
  }

  private func save() {
    guard !runtime.isReadOnly else {
      model.notice = "Unlock the file before saving."
      return
    }
    if reportedExternalConflict {
      let alert = NSAlert()
      alert.messageText = "The file changed on disk."
      alert.informativeText =
        "Saving now will replace the external version. Reload instead to keep the disk version."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Save Anyway")
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Reload")
      switch alert.runModal() {
      case .alertFirstButtonReturn: break
      case .alertThirdButtonReturn:
        performReloadFromDisk()
        return
      default: return
      }
    }
    statusSpinner?.startAnimation(nil)
    runtime.saveDocument()
    statusSpinner?.stopAnimation(nil)
    lastModificationDate = modificationDate()
    reportedExternalConflict = false
    updateToolbar()
  }

  private func renderContent() {
    guard isViewLoaded else { return }
    let content = showingPreview ? ensurePreviewContent() : ensureSourceContent()
    if content.superview !== contentHost {
      contentHost.removeAllSubviews()
      contentHost.addSubview(content)
      content.pinEdges(to: contentHost)
    }
    onSourceTextViewChanged?(showingPreview ? nil : sourceTextView)
    if showingPreview {
      schedulePreviewRendering()
    } else {
      scheduleSourceRendering()
      // 只预计算 HTML，不提前创建 WKWebView；这样打开仍轻量，首次切换也无需再等待
      // Markdown/RST 转换，WebKit 的一次性初始化留到用户真正需要预览时。
      schedulePreviewRendering()
    }
  }

  /// 源码视图在 Pane 生命周期内只创建一次。模式与锁定切换仅更新可编辑状态和层级，
  /// 因而保留滚动位置、选区、undo manager 以及 Workspace 的行跳转引用。
  private func ensureSourceContent() -> NSView {
    if let sourceScrollView {
      updateSourceLayout()
      return sourceScrollView
    }
    // 行号标尺按 NSLayoutManager 取行框，必须从创建起就用 TextKit 1。默认的 TextKit 2
    // 会在标尺首次绘制时被中途切换，切换前按零宽排出的折行残留到下一次整篇重排
    // （语法高亮完成）才消失，表现为切回标签后正文挤成一条窄列。
    let textView = FileSourceTextView(usingTextLayoutManager: false)
    // 拿到真实视口宽度前不跟随零宽 frame（否则容器宽为负，整篇按每字一行排版）；
    // 由 updateSourceLayout 在视口就绪后设定宽度并恢复跟随。
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.contextMenuProvider = { [weak self, weak textView] in
      guard let self, let textView else { return NSMenu() }
      return FilePaneMenus.source(textView: textView, syntax: makeSyntaxMenu(), viewAs: makeViewAsMenu(),
      json: makeJSONMenuActions(),
      reload: runtime.isReadOnly || fileURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) != false
        ? nil : { [weak self] in self?.reloadFromDisk() },
        sendToChat: { [weak self] in self?.sendCurrentContentToChat() })
    }
    sourceTextView = textView
    textView.isVerticallyResizable = true
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    textView.isEditable = presentationKind.supportsEditing && !runtime.isReadOnly
    textView.isSelectable = true
    textView.isRichText = false
    textView.allowsUndo = true
    textView.backgroundColor = NSColor(preferences.activeTheme.palette.renderedTerminalBackground)
    textView.textColor = NSColor(preferences.activeTheme.palette.foreground)
    textView.font = preferences.terminalFontVariants.normal
    textView.textContainerInset = NSSize(width: 16, height: 14)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.string = sourceText()
    let delegate = DocumentTextDelegate(runtime: runtime) { [weak self] in
      self?.scheduleSourceRendering(debounced: true)
      self?.schedulePreviewRendering(debounced: true)
    }
    documentDelegate = delegate
    textView.delegate = delegate
    let scroll = NSScrollView()
    scroll.wantsLayer = true
    scroll.layer?.masksToBounds = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    scroll.verticalRulerView = FileLineNumberRuler(scrollView: scroll, textView: textView)
    scroll.hasVerticalRuler = true
    scroll.hasHorizontalRuler = false
    scroll.rulersVisible = preferences.configuration.editor.showLineNumbers
    sourceScrollView = scroll
    updateSourceLayout()
    return scroll
  }

  private func updateSourceLayout() {
    guard let textView = sourceTextView, let scroll = sourceScrollView else { return }
    textView.isEditable = presentationKind.supportsEditing && !runtime.isReadOnly
    scroll.hasHorizontalScroller = !softWrap
    textView.isHorizontallyResizable = !softWrap
    // 宽度由这里按最终 viewport 统一设置；再开启 .width 会在 ruler tile 时重复扣减标尺宽度。
    textView.autoresizingMask = []
    // Pane 初次挂载和 Source/Preview 切换时滚动区可能尚未完成布局。显式跟随
    // viewport 建立文本视图尺寸，避免零宽 documentView 只加载文本而不绘制字形。
    // ruler 在 clip view 内占据负 x 区间，正文从 x=0 开始；去掉该区间才是可用宽度。
    scroll.tile()
    let clipBounds = scroll.contentView.bounds
    let viewport = NSSize(width: max(0, clipBounds.maxX - max(0, clipBounds.minX)), height: clipBounds.height)
    guard viewport.width > 0, viewport.height > 0 else { return }
    // 视口就绪后才开启宽度跟随，零宽阶段的 frame 不会把容器宽度带成负数。
    textView.textContainer?.widthTracksTextView = softWrap
    textView.minSize = viewport
    let size = NSSize(
      width: softWrap ? viewport.width : max(viewport.width, textView.frame.width),
      height: max(viewport.height, textView.frame.height)
    )
    if textView.frame.size != size { textView.setFrameSize(size) }
    textView.textContainer?.containerSize = NSSize(
      width: softWrap ? max(0, viewport.width - textView.textContainerInset.width * 2) : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
  }

  /// 同一 Pane 内就地更新主题和行号，保留文档、选区、撤销栈与预览实例。
  private func synchronizeEditorPresentation() {
    guard isViewLoaded else { return }
    softWrap = preferences.configuration.editor.lineWrap
    sourceScrollView?.rulersVisible = preferences.configuration.editor.showLineNumbers
    updateSourceLayout()
    let theme = preferences.activeTheme
    let font = preferences.terminalFontVariants.normal
    guard renderedTheme != theme || renderedFont != font else { return }
    renderedTheme = theme
    renderedFont = font
    toolbarView?.layer?.backgroundColor = NSColor(
      theme.resolvedColor(forSlot: "container.background") ?? theme.palette.containerBackground).cgColor
    sourceTextView?.backgroundColor = NSColor(theme.palette.renderedTerminalBackground)
    sourceTextView?.textColor = NSColor(theme.palette.foreground)
    sourceTextView?.font = font
    sourceScrollView?.verticalRulerView?.needsDisplay = true
    scheduleSourceRendering()
    if let web = previewWebView, let body = pendingPreviewBody { loadWebPreview(body, into: web) }
    if let web = transcriptWebView, let body = transcriptBody {
      web.loadHTMLString(AgentTranscriptHTML.document(body: body, style: FilePaneStyle(theme: theme)), baseURL: nil)
    }
    jsonTreeView?.apply(theme: theme, font: font)
    if let preview = cachedPreviewView as? QLPreviewView { applyPreviewTheme(preview) }
    if let pdf = cachedPreviewView as? PDFView { pdf.backgroundColor = NSColor(theme.palette.renderedTerminalBackground) }
    if presentationKind == .image, let scroll = cachedPreviewView as? NSScrollView {
      scroll.backgroundColor = NSColor(theme.palette.renderedTerminalBackground)
    }
  }

  private func sourceText() -> String {
    if !runtime.documentText.isEmpty || runtime.documentError == nil { return runtime.documentText }
    guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return runtime.documentError ?? "Unable to read this file."
    }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: Self.boundedPreviewBytes)
    if let text = String(data: data, encoding: .utf8) {
      let suffix =
        data.count == Self.boundedPreviewBytes ? "\n\n— Preview truncated at 4 MiB —" : ""
      return text + suffix
    }
    return makeHexPreview(data)
  }

  private func scheduleSourceRendering(debounced: Bool = false) {
    guard let textView = sourceTextView,
      [.sourceText, .diff, .markdown, .restructuredText, .html, .svg, .json, .agentTranscript].contains(presentationKind)
    else { return }
    sourceRenderRevision += 1
    let revision = sourceRenderRevision
    let text = textView.string
    let language = selectedLanguage ?? (presentationKind == .agentTranscript ? "json" : languageName(for: fileURL?.pathExtension.lowercased() ?? ""))
    let theme = preferences.activeTheme
    sourceRenderTask?.cancel()
    sourceRenderTask = Task { [weak self] in
      if debounced {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
      }
      guard let self,
        case .highlightedRTF(let data)? = await renderer.renderSource(text, language: language, theme: theme),
        !Task.isCancelled,
        revision == sourceRenderRevision,
        let textView = sourceTextView,
        textView.string == text, preferences.activeTheme == theme,
        let highlighted = try? NSAttributedString(
          data: data,
          options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil
        ), highlighted.string == text
      else { return }
      let selections = textView.selectedRanges
      guard let storage = textView.textStorage else { return }
      // 只替换属性，不替换字符；这样不会制造一轮伪编辑，也不会清空 undo 栈。
      storage.beginEditing()
      storage.setAttributes([:], range: NSRange(location: 0, length: storage.length))
      let fonts = preferences.terminalFontVariants
      highlighted.enumerateAttributes(
        in: NSRange(location: 0, length: highlighted.length)
      ) { attributes, range, _ in
        var adjusted = attributes
        let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        adjusted[.font] = traits.contains(.boldFontMask)
          ? (traits.contains(.italicFontMask) ? fonts.boldItalic : fonts.bold)
          : (traits.contains(.italicFontMask) ? fonts.italic : fonts.normal)
        storage.addAttributes(adjusted, range: range)
      }
      storage.endEditing()
      textView.typingAttributes = [.foregroundColor: NSColor(theme.palette.foreground),
        .font: fonts.normal]
      textView.selectedRanges = selections
    }
  }

  private func schedulePreviewRendering(text requestedText: String? = nil, debounced: Bool = false) {
    guard presentationKind.supportsSourcePreviewToggle else { return }
    let text = requestedText ?? sourceTextView?.string ?? sourceText()
    if renderedPreviewText == text, pendingPreviewBody != nil || pendingJSONResult != nil { return }
    previewRenderRevision += 1
    let revision = previewRenderRevision
    let renderer = self.renderer
    let kind = presentationKind
    previewRenderTask?.cancel()
    if showingPreview { statusSpinner?.startAnimation(nil) }
    previewRenderTask = Task { [weak self] in
      if debounced {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
      }
      let artifact = await renderer.renderPreview(text, kind: kind)
      guard let self else { return }
      if revision == previewRenderRevision, showingPreview {
        statusSpinner?.stopAnimation(nil)
      }
      guard !Task.isCancelled, revision == previewRenderRevision, let artifact else { return }
      switch artifact {
      case .webBody(let body):
        renderedPreviewText = text
        pendingPreviewBody = body
        if showingPreview {
          let webView = previewWebView ?? (ensurePreviewContent() as? WKWebView)
          if let webView { loadWebPreview(body, into: webView) }
        }
      case .jsonTree(let node):
        renderedPreviewText = text
        applyJSONResult(.success(node))
      case .jsonInvalid(let error):
        renderedPreviewText = text
        applyJSONResult(.failure(error))
      case .highlightedRTF:
        return
      }
    }
  }

  /// 记下最新 JSON 结果；树视图已存在时就地更新，并保留展开状态。
  private func applyJSONResult(_ result: Result<JSONNode, JSONParseError>) {
    pendingJSONResult = result
    jsonTreeView?.update(result: result)
  }

  /// 源码右键菜单里的 JSON 动作；非 JSON 文件返回 nil，菜单不显示这一组。
  private func makeJSONMenuActions() -> (format: () -> Void, minify: () -> Void)? {
    guard presentationKind == .json else { return nil }
    return (format: { [weak self] in self?.formatJSON(minify: false) },
      minify: { [weak self] in self?.formatJSON(minify: true) })
  }

  /// JSON 格式化 / 压缩当前编辑稿（含未保存修改），沿用文档原有缩进。
  /// 语法错误时不改文本，只提示出错行列。
  private func formatJSON(minify: Bool) {
    guard presentationKind == .json, let textView = sourceTextView as? FileSourceTextView,
      textView.isEditable
    else { return }
    let text = textView.string
    do {
      let formatted = minify
        ? try JSONDocumentFormatter.minify(text)
        : try JSONDocumentFormatter.format(text, indent: JSONDocumentFormatter.detectIndent(in: text))
      guard formatted != text else { return }
      textView.replaceAllText(formatted)
    } catch let error as JSONParseError {
      model.notice = error.localizedSummary
    } catch {
      model.notice = L("无法格式化 JSON。")
    }
  }

  private func ensurePreviewContent() -> NSView {
    if let cachedPreviewView { return cachedPreviewView }
    let preview = makePreviewContent()
    cachedPreviewView = preview
    return preview
  }

  private func makePreviewContent() -> NSView {
    guard let fileURL else { return messageView("No file selected.", symbol: "doc") }
    switch presentationKind {
    case .markdown, .restructuredText, .html, .svg:
      return makeWebPreview(baseURL: fileURL.deletingLastPathComponent())
    case .json:
      return makeJSONTree()
    case .image:
      guard let image = NSImage(contentsOf: fileURL) else {
        return messageView("Unable to decode this image.", symbol: "photo")
      }
      let imageView = FilePreviewImageView(image: image)
      imageView.contextMenuProvider = { [weak self, weak imageView] in
        guard let self else { return NSMenu() }
        return FileNativePreviewMenus.make(copy: {
          guard let image = imageView?.image else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.writeObjects([image])
        }, selectAll: nil, send: { [weak self] in self?.sendCurrentContentToChat() }, fileActions: fileActionsMenu())
      }
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.animates = true
      let scroll = NSScrollView()
      scroll.backgroundColor = NSColor(preferences.activeTheme.palette.renderedTerminalBackground)
      scroll.hasVerticalScroller = true
      scroll.hasHorizontalScroller = true
      scroll.allowsMagnification = true
      scroll.minMagnification = 0.1
      scroll.maxMagnification = 16
      scroll.documentView = imageView
      imageView.frame = NSRect(origin: .zero, size: image.size)
      return scroll
    case .pdf:
      let pdf = FilePreviewPDFView()
      pdf.contextMenuProvider = { [weak self, weak pdf] in
        guard let self else { return NSMenu() }
        return FileNativePreviewMenus.make(copy: pdf?.currentSelection?.string?.isEmpty == false ? { [weak pdf] in pdf?.copy(nil) } : nil,
          selectAll: { [weak pdf] in pdf?.selectAll(nil) }, send: { [weak self] in self?.sendCurrentContentToChat() }, fileActions: fileActionsMenu())
      }
      pdf.backgroundColor = NSColor(preferences.activeTheme.palette.renderedTerminalBackground)
      pdf.document = PDFDocument(url: fileURL)
      pdf.autoScales = true
      pdf.displayMode = .singlePageContinuous
      return pdf
    case .richDocument:
      guard preferences.configuration.editor.previewRichDocuments,
        let preview = FileQuickLookPreviewView(frame: .zero, style: .normal)
      else {
        return messageView("Rich document preview is disabled in Settings.", symbol: "doc.richtext")
      }
      preview.previewItem = fileURL as QLPreviewItem
      preview.contextMenuProvider = { [weak self, weak preview] in
        guard let self, preview != nil else { return NSMenu() }
        return FileNativePreviewMenus.quickLook(send: { [weak self] in self?.sendCurrentContentToChat() },
          fileActions: fileActionsMenu())
      }
      applyPreviewTheme(preview)
      return preview
    case .diff:
      return ensureSourceContent()
    case .agentTranscript:
      return makeAgentTranscript(fileURL)
    case .sourceText:
      return ensureSourceContent()
    case .binary:
      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let data = readPrefix(of: fileURL, maximumBytes: Self.boundedPreviewBytes)
      let hex = HexPreviewView(data: data, isTruncated: size > data.count)
      hex.contextMenuProvider = { [weak self, weak hex] in
        guard let self, let hex else { return NSMenu() }
        return FileNativePreviewMenus.make(copy: hex.selectedText().isEmpty ? nil : { [weak hex] in
          guard let text = hex?.selectedText(), !text.isEmpty else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }, selectAll: { [weak hex] in hex?.selectAllRows() }, send: { [weak self, weak hex] in
          guard let self else { return }
          let selection = hex?.selectedText()
          model.presentFileChat(FileChatContext(path: fileURL.path,
            selection: selection?.isEmpty == false ? selection : nil, lines: nil), originPaneID: runtime.id)
        }, fileActions: fileActionsMenu())
      }
      return hex
    }
  }

  private func makeJSONTree() -> NSView {
    let tree = FileJSONTreeView(theme: preferences.activeTheme, font: preferences.terminalFontVariants.normal)
    tree.onShowSource = { [weak self] in
      guard let self else { return }
      modeControl.selectedSegment = 0
      changePresentationMode()
    }
    tree.onSendToChat = { [weak self] in self?.sendCurrentContentToChat() }
    tree.fileActionsMenu = { [weak self] in self?.fileActionsMenu() ?? NSMenu() }
    if let pendingJSONResult { tree.update(result: pendingJSONResult) }
    jsonTreeView = tree
    return tree
  }

  private func applyPreviewTheme(_ preview: QLPreviewView) {
    let theme = preferences.activeTheme
    preview.wantsLayer = true
    preview.layer?.backgroundColor = NSColor(theme.palette.renderedTerminalBackground).cgColor
    preview.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
  }

  private func makeWebPreview(baseURL: URL) -> NSView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = FilePreviewWebView(frame: .zero, configuration: configuration)
    configurePreviewMenu(webView)
    webView.navigationDelegate = self
    previewWebView = webView
    loadWebPreview(pendingPreviewBody ?? "<p>Rendering preview…</p>", into: webView, baseURL: baseURL)
    return webView
  }

  private func loadWebPreview(_ body: String, into webView: WKWebView, baseURL: URL? = nil) {
    let document = """
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'">
      <style>
      body{font-family:-apple-system,system-ui,sans-serif;font-size:\(preferences.terminalFontVariants.normal.pointSize)px;margin:0 auto;max-width:760px;padding:24px;line-height:1.55}
      h1,h2,h3,h4,h5,h6{margin-top:1.5em} code{font-family:ui-monospace,monospace;font-size:.92em;padding:2px 4px;border-radius:3px;background:rgba(127,127,127,.11)} pre{padding:12px;overflow-x:auto;background:rgba(127,127,127,.11);border-radius:6px} pre code{background:transparent;padding:0}
      blockquote{border-left:3px solid #999;padding-left:12px;margin:1em 0} table{border-collapse:collapse} th,td{border:1px solid #aaa;padding:4px 8px} img,svg{max-width:100%;height:auto}
      \(FilePaneStyle(theme: preferences.activeTheme).previewCSS)
      </style></head><body>\(body)</body></html>
      """
    webView.loadHTMLString(document, baseURL: baseURL ?? fileURL?.deletingLastPathComponent())
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme?.lowercased()
    let isInitialFileDocument =
      scheme == "file"
      && navigationAction.navigationType == .other
      && navigationAction.targetFrame?.isMainFrame == true
    // `loadHTMLString(_:baseURL:)` 会把本地 baseURL 作为初始主文档 URL；必须允许这一次
    // `.other` 导航，Markdown/HTML/SVG 才能装载。用户点击的 file 或远程链接仍被拒绝，
    // 本地图片等子资源则不经过 main-frame navigation 决策。
    decisionHandler(
      scheme == nil || scheme == "about" || isInitialFileDocument ? .allow : .cancel)
  }

  private func makeReadOnlyTextView(
    text: String = "",
    attributed: NSAttributedString? = nil
  ) -> NSView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textColor = AsterTheme.ink
    textView.textContainerInset = NSSize(width: 18, height: 16)
    if let attributed {
      textView.textStorage?.setAttributedString(attributed)
    } else {
      textView.string = text
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = !softWrap
    scroll.documentView = textView
    return scroll
  }

  private func makeHexPreview<S: DataProtocol>(_ data: S) -> String {
    let bytes = Array(data)
    var lines: [String] = []
    lines.reserveCapacity(
      (bytes.count + HexLineFormatter.bytesPerLine - 1) / HexLineFormatter.bytesPerLine)
    for offset in stride(from: 0, to: bytes.count, by: HexLineFormatter.bytesPerLine) {
      let end = min(offset + HexLineFormatter.bytesPerLine, bytes.count)
      lines.append(HexLineFormatter.line(offset: offset, bytes: bytes[offset..<end]))
    }
    if bytes.count == Self.boundedPreviewBytes {
      lines.append("\n— Hex preview truncated at 4 MiB —")
    }
    return lines.joined(separator: "\n")
  }

  private func makeAgentTranscript(_ url: URL) -> NSView {
    guard
      let history = model.agentHistories.first(where: {
        $0.metadata.transcriptFileURL.standardizedFileURL == url.standardizedFileURL
      })
    else { return makeReadOnlyTextView(text: sourceText()) }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
    let title = NSTextField(labelWithString: history.metadata.title)
    title.font = NSFont.systemFont(ofSize: 19, weight: .bold)
    stack.addArrangedSubview(title)
    // 标题下给出会话文件与归属元信息（对齐 Otty 的会话页头）：文件名一行，
    // 项目路径 · provider · 更新时间一行，便于核对「这是哪个项目的哪次会话」。
    let fileLine = NSTextField(labelWithString: url.lastPathComponent)
    fileLine.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    fileLine.textColor = AsterTheme.tertiaryInk
    fileLine.lineBreakMode = .byTruncatingMiddle
    stack.addArrangedSubview(fileLine)
    var metaParts: [String] = []
    if !history.metadata.projectDirectory.isEmpty {
      metaParts.append((history.metadata.projectDirectory as NSString).abbreviatingWithTildeInPath)
    }
    metaParts.append(history.metadata.configuration.provider.commandName)
    metaParts.append(RelativeTime.string(since: history.metadata.updatedAt))
    let metaLine = NSTextField(labelWithString: metaParts.joined(separator: "  ·  "))
    metaLine.font = NSFont.systemFont(ofSize: 11)
    metaLine.textColor = AsterTheme.secondaryInk
    metaLine.lineBreakMode = .byTruncatingMiddle
    stack.addArrangedSubview(metaLine)
    let actions = NSStackView(views: [
      ActionButton(title: "Fork", bezelStyle: .rounded) { [weak self] in
        self?.model.continueAgentSession(history.metadata, kind: .fork)
      },
    ])
    actions.orientation = .horizontal
    stack.addArrangedSubview(actions)

    // 正文用与 Markdown 预览同源的加固 WKWebView（无 JS、CSP 锁死、无网络）渲染 HTML：
    // 用户消息进浅色卡片、Claude 输出按 Markdown 渲染、工具调用折叠成 <details> 摘要，
    // 展开是原生 HTML 行为。构建在主线程外完成——曾经逐条建 wrapping NSTextField 的
    // 实现在真实大会话上会把主线程卡死；HTML 拼装同样受单条/总量双重上限约束。
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = FilePreviewWebView(frame: .zero, configuration: configuration)
    configurePreviewMenu(webView)
    webView.navigationDelegate = self
    transcriptWebView = webView
    webView.loadHTMLString(
      AgentTranscriptHTML.document(body: "<p class=\"notice\">" + L("正在渲染会话…") + "</p>",
        style: FilePaneStyle(theme: preferences.activeTheme)), baseURL: nil)
    let entries = history.transcript.entries
    Task.detached(priority: .userInitiated) {
      let body = AgentTranscriptHTML.body(entries: entries)
      await MainActor.run { [weak self, weak webView] in
        guard let self, let webView, self.transcriptWebView === webView else { return }
        self.transcriptBody = body
        webView.loadHTMLString(AgentTranscriptHTML.document(body: body,
          style: FilePaneStyle(theme: self.preferences.activeTheme)), baseURL: nil)
      }
    }
    let body: NSView = webView

    let container = NSView()
    container.addSubview(stack)
    container.addSubview(body)
    stack.translatesAutoresizingMaskIntoConstraints = false
    body.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      body.topAnchor.constraint(equalTo: stack.bottomAnchor),
      body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }


  private func fileActionsMenu() -> NSMenu {
    guard let fileURL else { return NSMenu() }
    return FilePaneFileActions.menu(url: fileURL) { [weak self] message in self?.model.notice = message }
  }

  private func showFileActions() {
    guard let button = toolbarView?.openButton else { return }
    fileActionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
  }

  private func makeSyntaxMenu() -> NSMenu {
    FilePaneMenus.syntax(languages: syntaxLanguages, selected: selectedLanguage) { [weak self] language in
      self?.selectedLanguage = language
      self?.scheduleSourceRendering()
    }
  }

  private func makeViewAsMenu() -> NSMenu? {
    guard presentationKind == .agentTranscript else { return nil }
    let menu = NSMenu()
    for (index, title) in ["JSON/JSONL Syntax Highlight", "Agent History"].enumerated() {
      let item = ActionMenuItem(title: title) { [weak self] in
        self?.modeControl.selectedSegment = index
        self?.changePresentationMode()
      }
      item.state = showingPreview == (index == 1) ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  private func configurePreviewMenu(_ web: FilePreviewWebView) {
    web.onSendToChat = { [weak self] in self?.sendCurrentContentToChat() }
    web.onReloadFromDisk = { [weak self] in self?.reloadFromDisk() }
    web.allowsMagnification = true
    web.magnification = contentZoom
  }

  private func setContentZoom(_ zoom: Double) {
    contentZoom = zoom
    previewWebView?.magnification = zoom
    if let image = cachedPreviewView as? NSScrollView, presentationKind == .image { image.magnification = zoom }
  }

  private func zoomToFit() {
    if presentationKind == .image, let scroll = cachedPreviewView as? NSScrollView, let image = scroll.documentView,
      image.bounds.width > 0, image.bounds.height > 0 {
      toolbarView?.selectZoom(max(0.1, min(16, min(scroll.contentSize.width / image.bounds.width,
        scroll.contentSize.height / image.bounds.height))))
    } else { toolbarView?.selectZoom(1) }
  }

  private func runShellFile() {
    guard let fileURL else { return }
    // 与 Otty 一致，Run 执行磁盘上的脚本；当前编辑稿仍留在原 Pane，需显式保存。
    _ = model.runShellFile(fileURL)
  }

  private func resumeHistory() {
    guard let fileURL, let history = model.agentHistories.first(where: {
      $0.metadata.transcriptFileURL.standardizedFileURL == fileURL.standardizedFileURL
    }) else { return }
    model.continueAgentSession(history.metadata, kind: .resume)
  }

  /// 选区从当前视图捕获（包含未保存编辑）；预览的 DOM 查询也绑定发起时的文件 Pane。
  private func sendCurrentContentToChat() {
    guard let fileURL else { return }
    let paneID = runtime.id
    if !showingPreview, let source = sourceTextView {
      model.presentFileChat(.capture(path: fileURL.path, text: source.string, range: source.selectedRange()), originPaneID: paneID)
    } else if let web = previewWebView ?? transcriptWebView {
      Task { @MainActor [weak self, weak web] in
        guard let self, let web else { return }
        do {
          let selection = try await web.evaluateJavaScript("window.getSelection()?.toString() ?? ''") as? String
          guard self.tab?.runtime(for: paneID) === self.runtime else { return }
          self.model.presentFileChat(FileChatContext(path: fileURL.path,
            selection: selection?.isEmpty == false ? selection : nil, lines: nil), originPaneID: paneID)
        } catch {
          self.model.notice = L("无法读取预览选区，请重试。")
        }
      }
    } else if showingPreview, let tree = jsonTreeView {
      model.presentFileChat(FileChatContext(path: fileURL.path, selection: tree.selectionTextForChat(),
        lines: nil), originPaneID: paneID)
    } else if let pdf = cachedPreviewView as? PDFView {
      model.presentFileChat(FileChatContext(path: fileURL.path, selection: pdf.currentSelection?.string,
        lines: nil), originPaneID: paneID)
    } else {
      model.presentFileChat(FileChatContext(path: fileURL.path, selection: nil, lines: nil), originPaneID: paneID)
    }
  }

  private func reloadFromDisk() {
    if runtime.isDirty {
      let alert = NSAlert()
      alert.messageText = "Discard unsaved changes?"
      alert.informativeText =
        "Reloading replaces the current editor contents with the version on disk."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Reload")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    performReloadFromDisk()
  }

  private func performReloadFromDisk() {
    runtime.reloadDocument()
    if runtime.documentError == nil { sourceTextView?.undoManager?.removeAllActions() }
    classifyDocument()
    renderedPreviewText = nil
    pendingPreviewBody = nil
    lastModificationDate = modificationDate()
    reportedExternalConflict = false
    renderContent()
    updateToolbar()
  }

  private func startModificationMonitoring() {
    lastModificationDate = modificationDate()
    guard let directory = fileURL?.deletingLastPathComponent() else { return }
    let watcher = FileSystemDirectoryWatcher(directory: directory)
    do {
      try watcher.start { [weak self] in self?.checkForExternalModification() }
      modificationWatcher = watcher
    } catch {
      DiagnosticsCenter.shared.record(
        "file_pane.modification_watch_failed",
        level: .warning,
        category: .storage,
        error: error
      )
      modificationFallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
        [weak self] _ in MainActor.assumeIsolated { self?.checkForExternalModification() }
      }
      modificationFallbackTimer?.tolerance = 0.2
    }
  }

  private func modificationDate() -> Date? {
    guard let fileURL else { return nil }
    return try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
  }

  private func readPrefix(of url: URL, maximumBytes: Int) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return handle.readData(ofLength: maximumBytes)
  }

  private func checkForExternalModification() {
    let current = modificationDate()
    guard current != lastModificationDate else { return }
    lastModificationDate = current
    guard current != nil else {
      reportedExternalConflict = true
      updateToolbar()
      return
    }
    if runtime.isDirty {
      reportedExternalConflict = true
      updateToolbar()
    } else {
      runtime.reloadDocument()
      classifyDocument()
      renderContent()
    }
  }

  private func languageName(for fileExtension: String) -> String? {
    switch fileExtension {
    case "js", "jsx": "javascript"
    case "ts", "tsx": "typescript"
    case "py": "python"
    case "sh", "bash", "zsh": "bash"
    case "yml": "yaml"
    case "patch": "diff"
    case "md", "markdown": "markdown"
    default: fileExtension.isEmpty ? nil : fileExtension
    }
  }

  /// 空状态 / 出错提示：居中的图标加说明文字。
  private func messageView(_ message: String, symbol: String) -> NSView {
    let host = NSView()
    let image = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: message) ?? NSImage())
    let label = NSTextField(wrappingLabelWithString: message)
    label.font = NSFont.interface(ofSize: NSFont.systemFontSize)
    label.textColor = AsterTheme.secondaryInk
    let stack = NSStackView(views: [image, label])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    host.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
    ])
    return host
  }
}

/// 二进制预览只保留有界字节，并让 `NSTableView` 按可见行请求内容；即使达到 4 MiB
/// 上限也不会预先构造二十多万行字符串或同等数量的 AppKit 视图。
@MainActor
/// File Pane 根视图：外观（浅色/深色）变化时回调，供源码高亮按新主题重新渲染。
private final class AppearanceObservingView: NSView {
  var onEffectiveAppearanceChange: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onEffectiveAppearanceChange?()
  }
}

private final class HexPreviewView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
  private let data: Data
  private let isTruncated: Bool
  private weak var table: NSTableView?
  var contextMenuProvider: (() -> NSMenu)?

  init(data: Data, isTruncated: Bool) {
    self.data = data
    self.isTruncated = isTruncated
    super.init(frame: .zero)
    let table = NSTableView()
    self.table = table
    table.allowsMultipleSelection = true
    table.menu = NSMenu()
    table.menu?.delegate = self
    table.headerView = nil
    table.style = .plain
    table.backgroundColor = .clear
    table.rowHeight = 19
    table.intercellSpacing = .zero
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hex")))
    table.dataSource = self
    table.delegate = self
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.documentView = table
    addSubview(scroll)
    scroll.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }

  func menuWillOpen(_ menu: NSMenu) {
    menu.removeAllItems()
    guard let actions = contextMenuProvider?() else { return }
    menu.autoenablesItems = false
    for item in actions.items { actions.removeItem(item); menu.addItem(item) }
  }

  func selectAllRows() { table?.selectAll(nil) }

  func selectedText() -> String {
    guard let table else { return "" }
    return table.selectedRowIndexes.compactMap { row -> String? in
      let start = row * HexLineFormatter.bytesPerLine
      guard start < data.count else { return nil }
      let bytes = Array(data[start..<min(start + HexLineFormatter.bytesPerLine, data.count)])
      return HexLineFormatter.line(offset: start, bytes: bytes[...])
    }.joined(separator: "\n")
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    let dataRows = (data.count + HexLineFormatter.bytesPerLine - 1) / HexLineFormatter.bytesPerLine
    return dataRows + (isTruncated ? 1 : 0)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let dataRows = (data.count + HexLineFormatter.bytesPerLine - 1) / HexLineFormatter.bytesPerLine
    let identifier = NSUserInterfaceItemIdentifier("hex-row")
    let label =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
      ?? NSTextField(labelWithString: "")
    label.identifier = identifier
    label.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    label.textColor = AsterTheme.ink
    if row >= dataRows {
      label.stringValue = "— Hex preview truncated at 4 MiB —"
      label.textColor = AsterTheme.secondaryInk
    } else {
      let offset = row * HexLineFormatter.bytesPerLine
      let end = min(offset + HexLineFormatter.bytesPerLine, data.count)
      label.stringValue = HexLineFormatter.line(
        offset: offset,
        bytes: Array(data[offset..<end])[...]
      )
    }
    return label
  }
}
