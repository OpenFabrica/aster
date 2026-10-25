import AppKit
import AsterCore
import Foundation
@preconcurrency import GhosttyKit

/// Autocomplete 只依赖“发送字节、核对可见 prompt、提供 caret 视觉令牌”这组窄接口，
/// 不绑定 SwiftTerm 或 Ghostty 的网格实现。两个引擎都在各自 adapter 内完成坐标转换。
@MainActor
protocol TerminalAutocompleteHost: AnyObject {
  var autocompleteContainerView: NSView { get }
  var autocompleteCaretFrame: NSRect { get }
  var autocompleteFont: NSFont { get }
  var autocompleteForegroundColor: NSColor { get }
  var autocompleteBackgroundColor: NSColor { get }
  func sendAutocompleteBytes(_ bytes: ArraySlice<UInt8>) -> Bool
  func visiblePromptEnds(with text: String) -> Bool
  func visibleShellSuggestion(after text: String) -> String?
  /// 输入法是否正在组字。组字期间的回车是「上屏」，绝不能被补全吞掉。
  var autocompleteHasMarkedText: Bool { get }
}

/// 按目录保存的项目会话恢复命令。工作区仍维护此值，新补全不把它直接注入候选。
struct ProjectCommandSuggestion: Equatable {
  let command: String
  let description: String
}

/// 只接受紧接真实光标的可见后缀；长空白后的右侧提示符不属于补全。
private func shellSuggestionSuffix(prefix: String, typed: String, suffix: String) -> String? {
  guard !typed.isEmpty, prefix.hasSuffix(typed) else { return nil }
  let value = suffix.components(separatedBy: "  ").first?
    .trimmingCharacters(in: .newlines) ?? ""
  guard !value.trimmingCharacters(in: .whitespaces).isEmpty, value.utf8.count <= 4_096,
    !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  else { return nil }
  return value
}

extension AsterTerminalView: TerminalAutocompleteHost {
  var autocompleteContainerView: NSView { self }
  var autocompleteCaretFrame: NSRect { caretFrame }
  var autocompleteFont: NSFont { font }
  var autocompleteForegroundColor: NSColor { nativeForegroundColor }
  var autocompleteBackgroundColor: NSColor { nativeBackgroundColor }

  func sendAutocompleteBytes(_ bytes: ArraySlice<UInt8>) -> Bool {
    send(data: bytes)
    return true
  }

  func visiblePromptEnds(with text: String) -> Bool {
    let terminal = getTerminal()
    guard let line = terminal.getLine(row: terminal.buffer.y) else { return false }
    let prefix = line.translateToString(
      trimRight: false, startCol: 0, endCol: terminal.buffer.x,
      skipNullCellsFollowingWide: true)
    let suffix = line.translateToString(
      trimRight: true, startCol: terminal.buffer.x,
      skipNullCellsFollowingWide: true)
    return prefix.hasSuffix(text) && suffix.trimmingCharacters(in: .whitespaces).isEmpty
  }
  var autocompleteHasMarkedText: Bool { hasMarkedText() }
  func visibleShellSuggestion(after text: String) -> String? {
    let terminal = getTerminal()
    guard let line = terminal.getLine(row: terminal.buffer.y) else { return nil }
    return shellSuggestionSuffix(
      prefix: line.translateToString(trimRight: false, startCol: 0, endCol: terminal.buffer.x,
        skipNullCellsFollowingWide: true),
      typed: text,
      suffix: line.translateToString(trimRight: true, startCol: terminal.buffer.x,
        skipNullCellsFollowingWide: true))
  }

}

extension GhosttySurfaceView: TerminalAutocompleteHost {
  var autocompleteContainerView: NSView { self }
  var autocompleteCaretFrame: NSRect {
    let frame = textCursorFrameInViewCoordinates
    guard let surface, bounds.width > 0 else { return .zero }
    let size = ghostty_surface_size(surface)
    guard size.width_px > 0 else { return .zero }
    // IME x 是单元格中点，width 是预编辑宽度（通常为 0），不是 caret 宽度。
    // 补全应从当前空单元格左缘开始，避免半格错位；IME 自身继续保留原坐标。
    let cellWidth = CGFloat(size.cell_width_px) * bounds.width / CGFloat(size.width_px)
    return NSRect(x: frame.minX - cellWidth / 2, y: frame.minY, width: 0, height: frame.height)
  }
  var autocompleteFont: NSFont {
    guard let surface, let fontPointer = ghostty_surface_quicklook_font(surface) else {
      // Surface 尚未创建或当前字体后端无法导出 CoreText 字体时，补全也不会具备可靠的
      // cursor 锚点；保留无副作用的系统字体仅用于防御性降级。
      return .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
    // libghostty 返回 +1 retained CTFontRef，且 CoreText 与 NSFont 在 macOS 上可桥接。
    // 由 ARC 接管所有权，并使用与 Metal 网格相同的 face/size，保证相邻字形基线一致。
    return Unmanaged<NSFont>.fromOpaque(fontPointer).takeRetainedValue()
  }
  /// 候选文字必须与面板底色(主题 surface)配对,而不是跟随系统 `.textColor`:深色终端
  /// 主题下 surface 可能是浅色,系统文字色却解析成白色,导致白字压在浅底上看不清。
  var autocompleteForegroundColor: NSColor { AsterTheme.ink }
  var autocompleteBackgroundColor: NSColor { AsterTheme.panel }

  func sendAutocompleteBytes(_ bytes: ArraySlice<UInt8>) -> Bool {
    sendBytes(Array(bytes))
  }

  func visiblePromptEnds(with text: String) -> Bool {
    guard let info = bufferInfo(), !info.alternate_screen,
      info.cursor.screen_row >= info.viewport_top,
      info.cursor.screen_row < info.viewport_top + UInt64(info.viewport_rows),
      let suffix = readLine(at: info.cursor, startingAt: info.cursor.column),
      suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    if info.cursor.column == 0 { return text.isEmpty }
    guard let prefix = readLine(
      at: info.cursor, startingAt: 0, endingAt: info.cursor.column - 1)
    else { return false }
    return prefix.trimmingCharacters(in: .newlines).hasSuffix(text)
  }
  var autocompleteHasMarkedText: Bool { hasMarkedText() }
  func visibleShellSuggestion(after text: String) -> String? {
    guard let info = bufferInfo(), !info.alternate_screen, info.cursor.column > 0,
      info.cursor.screen_row >= info.viewport_top,
      info.cursor.screen_row < info.viewport_top + UInt64(info.viewport_rows),
      let prefix = readLine(at: info.cursor, startingAt: 0, endingAt: info.cursor.column - 1),
      let suffix = readLine(at: info.cursor, startingAt: info.cursor.column)
    else { return nil }
    return shellSuggestionSuffix(prefix: prefix.trimmingCharacters(in: .newlines), typed: text, suffix: suffix)
  }

}

/// 终端按键到 Autocomplete 意图的稳定映射。物理 keyCode 用于不受当前键盘布局影响的
/// 导航键；Control-Space 等文字组合仍检查 modifier，避免吞掉普通空格。
enum TerminalAutocompleteKey: Equatable {
  case tab
  case left
  case right
  case up
  case down
  case enter
  case escape
  case optionEscape
  case controlSpace
  case functionFive
  case backspace
  /// ⇧⌫（含 ⇧ + 前向删除）：面板里忘记选中的历史候选。
  case shiftDelete
  case other

  static func resolve(_ event: NSEvent) -> TerminalAutocompleteKey {
    switch event.keyCode {
    case 48: return .tab
    case 123: return .left
    case 124: return .right
    case 126: return .up
    case 125: return .down
    case 36, 76: return .enter
    case 53 where event.modifierFlags.contains(.option): return .optionEscape
    case 53: return .escape
    case 96: return .functionFive
    case 51 where event.modifierFlags.contains(.shift), 117 where event.modifierFlags.contains(.shift):
      return .shiftDelete
    case 51: return .backspace
    default:
      if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
        return .controlSpace
      }
      return .other
    }
  }
}

/// 候选面板的显式状态。
///
/// 这里刻意不用裸 Bool:旧实现里 `receiveInput` 把它置 false、`refreshNow` 又无条件
/// 重算成 true,两处互相覆写,直接导致两个缺陷——`escape` 模式下手动打开的面板一敲键
/// 就被打字关掉(Otty 要求“继续打字来收窄”),`auto` 模式下 Esc 关掉的面板又被下一次
/// 刷新弹回来。可见性现在只在 `refreshNow` 的迁移 switch 里改写,其它路径一律只读。
enum AutocompletePanelState: Equatable {
  case hidden
  /// `origin` 决定设置切换时是否关闭面板；自动展开不代表用户已作出选择。
  case open(origin: Origin, userSelected: Bool)

  enum Origin: Equatable {
    case automatic
    case manual
  }
}

/// 单个终端 Pane 的补全编排器。领域候选和持久化由 `AsterCore` / `AutocompleteService`
/// 负责；这里仅把 OSC 133、键盘输入和 AppKit overlay 串起来。
@MainActor
final class TerminalAutocompleteController {
  private weak var terminalView: (any TerminalAutocompleteHost)?
  private let service: AutocompleteService
  private let sessionIdentifier: String
  private let controls: () -> ControlConfiguration
  private let currentDirectory: () -> String
  private let tracker = PromptInputTracker()
  private let overlay = TerminalAutocompleteOverlayView()

  private(set) var currentResult = AutocompleteResult.empty
  private(set) var panelState: AutocompletePanelState = .hidden
  /// 保留旧名字给外部读取与既有测试,语义不变。
  var panelVisible: Bool { panelState != .hidden }
  /// 面板是否呈现当前选中行。
  var hasUserSelection: Bool {
    if case .open(_, true) = panelState { true } else { false }
  }
  private(set) var selectedIndex = 0
  /// 滚动视窗的首行下标。放在控制器而不是 overlay:它是选择状态的一部分,必须能在
  /// 不触发 AppKit 布局的前提下被测试断言。
  private(set) var firstVisibleIndex = 0
  /// 用户在本轮 prompt 内按 Esc 关过面板。作用域刻意是“整条 prompt”而不是“当前
  /// token”:Esc 的语义是“我不要这个下拉”,按 token 清零会让面板在空格后又跳出来,
  /// 等于没关。
  private var panelSuppressedForPrompt = false
  private(set) var promptActive = false
  private(set) var lastSubmittedCommand: String?
  /// Ghostty 的 OSC 与 PTY write 来自不同 callback，C marker 可能抢在最后一个回车的
  /// 主线程投递前到达。仅在“commandStart 已到、但本轮命令尚未提交”时保持一次有界
  /// 接收窗口；拿到换行后立即关闭，运行中的 TUI 按键不会进入 Shell 命令跟踪器。
  private var acceptsLateSubmittedInput = false
  /// 命令文本只在当前 Pane 内存中用于自动进度匹配，不进入工作区快照或日志。
  var onCommandSubmitted: ((String) -> Void)?
  private var refreshTask: Task<Void, Never>?
  private(set) var dynamicTask: Task<Void, Never>?
  private(set) var fallbackTabTask: Task<Void, Never>?
  private var dynamicGeneration: UInt64 = 0
  private(set) var shellCompletionActive = false
  private var helpProbeTask: Task<Void, Never>?
  private var probedCommands: Set<String> = []
  private var helpProbeGeneration: UInt64 = 0
  private var isInvalidated = false
  private var runningCommand: String?
  private var recordedCommandForPrompt = false
  /// OSC 133 C 时终端网格上真实的命令行。键盘重建（tracker）在用户按 ↑ 调历史、
  /// 接受 shell 自身建议或 Tab 补全后会缺失/不完整，学习以实际提交文本为准。
  private var screenCommand: String?
  private var aliases: [String] = []
  private var inlineDismissed = false
  /// 本地输入会先于 PTY 回显到达。等待回显期间保留候选数据但隐藏 ghost，避免它
  /// 锚定在旧 caretFrame 上并与 Shell 随后绘制的输入文字重叠。
  private var awaitingInputEcho = false
  /// Ctrl-C 或 prompt A 到 B 的过渡期，Shell 会保留已经写入 PTY 的 typeahead。
  /// 跟踪器也必须保留它，不能因 prompt 尚未就绪而丢掉命令前缀。
  private var pendingPromptInput: [UInt8]?
  private var pendingPromptInputOverflowed = false
  init(
    service: AutocompleteService,
    sessionIdentifier: String,
    controls: @escaping () -> ControlConfiguration,
    currentDirectory: @escaping () -> String
  ) {
    self.service = service
    self.sessionIdentifier = sessionIdentifier
    self.controls = controls
    self.currentDirectory = currentDirectory
    helpProbeGeneration = service.helpProbeGeneration
    overlay.onCandidateSelected = { [weak self] index in
      self?.acceptCandidate(at: index)
    }
  }

  deinit {
    refreshTask?.cancel()
    dynamicTask?.cancel()
    fallbackTabTask?.cancel()
    helpProbeTask?.cancel()
  }

  /// Pane 替换或关闭控制器时同步撤销所属 pending，避免异步析构清掉新控制器的命令。
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    helpProbeTask?.cancel()
    service.cancelPending(sessionIdentifier: sessionIdentifier)
    dismiss()
  }

  func attach(to terminalView: any TerminalAutocompleteHost) {
    self.terminalView = terminalView
    let container = terminalView.autocompleteContainerView
    container.addSubview(overlay, positioned: .above, relativeTo: nil)
    overlay.frame = container.bounds
    overlay.autoresizingMask = [.width, .height]
    render()
  }

  func receive(_ event: ShellIntegrationEvent) {
    guard !isInvalidated else { return }
    switch event {
    case .promptStart:
      // A 只表示 prompt 即将开始；必须等 B 确认输入区已出现，避免慢 prompt 绘制期间
      // 把候选锚定到中间输出位置。
      promptActive = false
      if pendingPromptInput == nil {
        pendingPromptInput = []
        pendingPromptInputOverflowed = false
      }
      tracker.beginPrompt()
      inlineDismissed = false
      awaitingInputEcho = false
      acceptsLateSubmittedInput = false
      panelSuppressedForPrompt = false
      screenCommand = nil
      dismiss()
    case .inputStart:
      // B 明确表示光标已进入可编辑区。A 缺失时仍可从此处开始安全跟踪。
      if !promptActive {
        promptActive = true
        tracker.beginPrompt()
      }
      lastSubmittedCommand = nil
      recordedCommandForPrompt = false
      acceptsLateSubmittedInput = true
      awaitingInputEcho = false
      panelSuppressedForPrompt = false
      let buffered = pendingPromptInput ?? []
      pendingPromptInput = nil
      if pendingPromptInputOverflowed {
        tracker.invalidate()
        dismiss()
      } else if !buffered.isEmpty {
        receiveInput(buffered[...])
      } else {
        scheduleRefresh()
      }
      pendingPromptInputOverflowed = false
    case .commandStart:
      pendingPromptInput = nil
      pendingPromptInputOverflowed = false
      promptActive = false
      runningCommand = screenCommand ?? lastSubmittedCommand
      if let runningCommand { submitForLearning(runningCommand) }
      // 正常顺序下提交回调已经给出命令，无需继续接收；只有 nil 才表示 PTY write
      // 仍排在主线程队列中，允许它补齐到第一个换行。
      acceptsLateSubmittedInput = runningCommand == nil
      dismiss()
    case .commandFinished(let exitStatus):
      acceptsLateSubmittedInput = false
      finishCommand(exitStatus: exitStatus)
      runningCommand = nil
      dismiss()
    }
  }

  /// 终端在 commandStart 时读到的命令行文本；规范化失败时视为没有。
  func receiveScreenCommand(_ text: String) {
    guard !isInvalidated else { return }
    screenCommand = Self.normalizedScreenCommand(text).map {
      // 共享规范化用于 Agent/SSH，学习另外保留前导空格的“不记录”语义。
      text.hasPrefix(" ") ? " " + $0 : $0
    }
  }

  /// 把网格上读到的命令行规范化为可信命令文本。只取第一段（右侧提示符与命令之间
  /// 至少两个空格），并拒绝控制字符与超长内容；空文本返回 nil。Session 的 SSH
  /// 分组与补全学习共用这一条规则，避免两处对屏幕文本解释不一致。
  static func normalizedScreenCommand(_ text: String) -> String? {
    let firstSegment = text.components(separatedBy: "  ").first ?? text
    let trimmed = firstSegment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096,
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return trimmed
  }

  func receiveInput(_ bytes: ArraySlice<UInt8>) {
    guard !isInvalidated else { return }
    if promptActive || pendingPromptInput != nil,
      let interrupt = bytes.lastIndex(of: 0x03)
    {
      pendingPromptInput = []
      pendingPromptInputOverflowed = false
      promptActive = false
      acceptsLateSubmittedInput = false
      tracker.beginPrompt()
      dismiss()
      bufferPromptInput(bytes[bytes.index(after: interrupt)...])
      return
    }
    if pendingPromptInput != nil {
      bufferPromptInput(bytes)
      return
    }
    guard promptActive || acceptsLateSubmittedInput else { return }
    let submitted = tracker.receive(Array(bytes))
    if let command = submitted.last {
      // ↑ 历史和 Shell Tab 的最终文本不在输入字节里；等待 OSC C 的屏幕回读。
      if tracker.isReliable {
        lastSubmittedCommand = command
        // commandStart 已抢先时补回 runningCommand，后续完成学习仍消费同一条真值。
        if runningCommand == nil { runningCommand = command }
        submitForLearning(command)
        onCommandSubmitted?(command.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      promptActive = false
      acceptsLateSubmittedInput = false
      dismiss()
      return
    }
    // commandStart 之后只负责吃完已排队的本轮输入；不再显示候选或启动 help probe。
    guard promptActive else { return }
    guard tracker.isReliable else {
      dismiss()
      return
    }
    inlineDismissed = false
    awaitingInputEcho = true
    // 打字**不关闭面板**,只清掉待重算的候选。Otty 的语义是“继续打字来收窄候选”,
    // 旧实现在这里无条件把面板关掉,于是手动打开的面板每敲一个字符就消失一次。
    // 自动面板在新输入后撤销旧选择，等待用户重新选择；手动打开的面板保持导航模式。
    if case .open(.automatic, _) = panelState {
      panelState = .open(origin: .automatic, userSelected: false)
    }
    // 候选重算有 debounce，而 PTY 回显会在这段窗口内继续推进终端网格。若保留上一轮
    // ghost，旧后缀会短暂覆盖新输入；先清空可见候选，待新输入回显并重算后再显示。
    clearCandidatesForRefilter()
    render()
    scheduleRefresh()
  }

  private func bufferPromptInput(_ bytes: ArraySlice<UInt8>) {
    guard !pendingPromptInputOverflowed else { return }
    guard (pendingPromptInput?.count ?? 0) + bytes.count <= 4_096 else {
      pendingPromptInput = []
      pendingPromptInputOverflowed = true
      return
    }
    pendingPromptInput?.append(contentsOf: bytes)
  }

  func receiveOutput(_ bytes: ArraySlice<UInt8>) {
    guard !isInvalidated else { return }
    guard promptActive else { return }
    // 输出可能是 Shell 异步建议或重绘。有待回显的本地输入时立即撤下旧 ghost，避免它
    // 锚定旧 caretFrame 与新输入叠字；没有待回显输入（空 prompt 上的时钟/异步提示符
    // 重绘）时不先隐藏，否则每次重绘 ghost 都会闪一下，看起来像窗口在抖动。
    let previouslyAwaiting = awaitingInputEcho
    // ghost 布局必须等终端 surface 消费完回显并更新 caretFrame。
    // 终端的状态报告、光标控制等同样会走 PTY 输出，
    // 因此不能把“收到任意输出”当成回显完成，否则 ghost 会锚定旧光标并覆盖输入。
    Task { @MainActor [weak self] in
      guard let self, self.promptActive else { return }
      let awaiting = !self.currentPromptIsEchoed()
      guard awaiting != self.awaitingInputEcho || previouslyAwaiting else { return }
      self.awaitingInputEcho = awaiting
      self.render()
    }
  }

  func receiveAliases(_ names: [String]) {
    guard !isInvalidated else { return }
    guard aliases != names else { return }
    aliases = names
    if promptActive { scheduleRefresh() }
  }

  /// Shell 上报的 `$PATH`：交给服务重建可执行文件索引，索引是全局的、不按 Pane 保存。
  func receiveSearchPath(_ directories: [String]) {
    guard !isInvalidated else { return }
    service.updateSearchPath(directories)
  }

  @discardableResult
  func handleKeyDown(_ event: NSEvent) -> Bool {
    guard terminalView?.autocompleteHasMarkedText != true else { return false }
    return handle(TerminalAutocompleteKey.resolve(event))
  }

  @discardableResult
  func handle(_ key: TerminalAutocompleteKey) -> Bool {
    guard !isInvalidated else { return false }
    if shellCompletionActive {
      if [.tab, .left, .right, .up, .down].contains(key) { return false }
      shellCompletionActive = false
    }
    if key == .shiftDelete { return forgetSelectedCandidate() }
    if key == .backspace {
      // Backspace 本身仍交给 Shell；这里只清掉旧候选，输入回调随后按新文本重算。
      // 面板保持打开:Otty 的退格是“清掉 ghost”,不是“关掉下拉”。
      clearCandidatesForRefilter()
      render()
      return false
    }

    let configuration = controls()
    if key == .controlSpace, configuration.resolvedAutocompleteShortcut == .controlSpace {
      // 原版 Ctrl-Space 触发重新查询，不向 PTY 写候选。
      if case .open(let origin, _) = panelState { panelState = .open(origin: origin, userSelected: false) }
      inlineDismissed = false
      refreshNow()
      return true
    }
    if key == .tab, configuration.resolvedAutocompleteShortcut == .rightArrow { return false }
    if case .open(let origin, let userSelected) = panelState {
      switch key {
      case .up, .down:
        guard !currentResult.candidates.isEmpty else { return true }
        if !userSelected {
          // 自动弹出的面板此前没有选中行,第一个方向键要落在第 0 / 末行本身,
          // 而不是在隐含的第 0 行基础上再移动一格跳过第一条。
          selectedIndex = key == .down ? 0 : currentResult.candidates.count - 1
        } else {
          let delta = key == .down ? 1 : currentResult.candidates.count - 1
          selectedIndex = (selectedIndex + delta) % currentResult.candidates.count
        }
        panelState = .open(origin: origin, userSelected: true)
        inlineDismissed = false
        updateVisibleWindow()
        render()
        return true
      case .enter:
        guard userSelected else { dismiss(); return false }
        return acceptCandidate(at: selectedIndex)
      case .tab, .right:
        guard Self.accepts(key, shortcut: configuration.resolvedAutocompleteShortcut) else { return false }
        if userSelected {
          return acceptCandidate(at: selectedIndex)
        }
        if currentResult.candidates.count == 1 {
          // 原版 show 将索引重置为 -1；单项会进入 accept，但 selectedItem 为 nil。
          // 该分支仅清理且吞掉按键，不补选首项，也不插入 ghost。
          dismiss()
          return true
        }
        let firstIsWholeLine = currentResult.candidates.first.map {
          $0.kind == .learnedCommand || $0.kind == .correction
        } ?? false
        if inlineGhostText != nil, key == .right || firstIsWholeLine {
          return acceptCandidate(at: 0)
        }
        if key == .tab { shellCompletionActive = true; dismiss() }
        return false
      case .escape, .optionEscape:
        panelState = .hidden
        panelSuppressedForPrompt = true
        inlineDismissed = true
        render()
        return true
      default:
        break
      }
    }

    let acceptsInline = Self.accepts(key, shortcut: configuration.resolvedAutocompleteShortcut)
    // 只允许接受屏幕上真正显示的 ghost。等待回显期间（含 zsh-autosuggestions 等
    // shell 端建议占据行尾、导致回显校验一直不通过的场景）候选是不可见的；此时吞掉
    // Tab 会插入用户从未见过的文本，必须把按键放行给 Shell 自己的补全。
    if acceptsInline, inlineSuggestionDisplayable {
      switch inlineSuggestion {
      case .candidate(let index) where currentResult.ghostText != nil:
        return acceptCandidate(at: index)
      default:
        break
      }
    }
    // Shell 插件已经画出的后缀也是用户可见的建议。接受它时只发文字，绝不发送 Tab，
    // 避免落入 zsh 的 “show all possibilities” 分支或再次打开 Aster 面板。
    if acceptsInline, promptActive, tracker.isReliable, tracker.isCursorAtEnd,
      let terminalView, let suffix = terminalView.visibleShellSuggestion(after: tracker.line)
    {
      dismiss()
      return terminalView.sendAutocompleteBytes(Array(suffix.utf8)[...])
    }
    if key == .tab, acceptsInline {
      return queryWithFallbackTab(configuration: configuration)
    }

    if key == .escape, inlineGhostText != nil, inlineSuggestionDisplayable {
      inlineDismissed = true
      render()
      return true
    }

    let opensPanel: Bool
    switch configuration.resolvedAutocompleteCandidatePanel {
    case .disabled: opensPanel = false
    // `auto` 模式下 Esc 兼任“再给我看一次”:Esc 关闭后本轮 prompt 的自动弹出被闩锁
    // 挡住,没有这条用户就再也打不开面板了。
    case .automatic, .escape: opensPanel = key == .escape
    case .optionEscape: opensPanel = key == .optionEscape || key == .functionFive
    }
    if opensPanel, !currentResult.candidates.isEmpty {
      panelState = .open(origin: .manual, userSelected: false)
      panelSuppressedForPrompt = false
      selectedIndex = 0
      updateVisibleWindow()
      render()
      return true
    }
    return false
  }

  private static func accepts(_ key: TerminalAutocompleteKey, shortcut: AutocompleteShortcut) -> Bool {
    switch shortcut {
    case .tab: key == .tab
    case .tabAndRightArrow: key == .tab || key == .right
    case .rightArrow: key == .right
    case .controlSpace: key == .controlSpace
    case .disabled: false
    }
  }

  /// 测试和立即设置变更使用的同步刷新 seam；正常输入通过 150ms debounce 调用。
  func refreshNow() {
    refreshTask?.cancel()
    cancelDynamicQuery()
    guard !isInvalidated, promptActive, tracker.isReliable, tracker.isCursorAtEnd else {
      dismiss()
      return
    }
    let configuration = controls()
    // Otty:inline suggestion 与候选面板同时关闭 = 整个功能停用,连内置规格库都不
    // 查询。本机学习是另一个开关，命令记录不受这里影响。
    guard configuration.resolvedAutocompleteInlineSuggestion
      || configuration.resolvedAutocompleteCandidatePanel != .disabled
    else {
      dismiss()
      return
    }
    let result = service.suggestions(
      line: tracker.line,
      directory: currentDirectory(),
      sessionIdentifier: sessionIdentifier,
      controls: configuration,
      aliases: aliases
    )
    applyResult(result, configuration: configuration)
    scheduleDynamicQuery(configuration: configuration)
    scheduleHelpProbeIfNeeded(configuration: configuration)
  }

  private func applyResult(_ result: AutocompleteResult, configuration: ControlConfiguration) {
    // 查询完成时可能已经通过方向键选择。保留该候选身份，不让新排序把 Tab 指向别项。
    let selected = hasUserSelection && currentResult.candidates.indices.contains(selectedIndex)
      ? currentResult.candidates[selectedIndex] : nil
    currentResult = result
    if let selected {
      if let index = result.candidates.firstIndex(where: {
        $0.insertText == selected.insertText && $0.replacement == selected.replacement
      }) {
        selectedIndex = index
      } else if case .open(let origin, _) = panelState {
        // 来源改变或候选达到上限可能移除选中项；旧索引不等于用户选择了新项。
        panelState = .open(origin: origin, userSelected: false)
        selectedIndex = 0
      }
    }
    selectedIndex = min(selectedIndex, max(0, result.candidates.count - 1))
    // 面板可见性的唯一迁移点。旧实现在这里无条件重算、又在 receiveInput 里置 false,
    // 两处互相覆写;所有其它路径现在只读 `panelState`。
    switch (panelState, configuration.resolvedAutocompleteCandidatePanel) {
    case _ where result.candidates.isEmpty:
      panelState = .hidden
    case (_, .disabled):
      panelState = .hidden
    case (.hidden, .automatic):
      // 空 prompt 不自动弹面板：新开 Pane 或命令刚结束时用户还没表达任何意图，
      // 候选仍然计算；用户输入或按 Esc/Tab 主动打开时再展开。
      if !panelSuppressedForPrompt, !tracker.line.isEmpty, !result.candidates.isEmpty {
        panelState = .open(origin: .automatic, userSelected: false)
      }
    case (.hidden, _):
      break
    case (.open(.automatic, _), .automatic):
      // 自动面板随输入退格清空而收起：空 prompt 上的候选只是目录历史，与上面
      // 「空 prompt 不自动弹面板」同一语义；用户再敲字符会重新展开。手动打开的面板
      // 不受影响（下面的 .manual 分支）。
      if result.candidates.isEmpty || tracker.line.isEmpty { panelState = .hidden }
    case (.open(.automatic, _), _):
      // 配置从 auto 改掉时,收起此前自动弹出的面板。
      panelState = .hidden
    case (.open(.manual, let selected), _):
      panelState = result.candidates.isEmpty
        ? .hidden : .open(origin: .manual, userSelected: selected)
    }
    updateVisibleWindow()
    render()
  }

  /// 异步结果只属于发起它的 prompt、输入、目录、别名和设置快照。取消本身不足以
  /// 保证隔离，因为文件读取和被注入的提供器可能在取消之后才返回。
  private func scheduleDynamicQuery(configuration: ControlConfiguration) {
    let line = tracker.line
    let directory = currentDirectory()
    let capturedAliases = aliases
    let generation = dynamicGeneration
    dynamicTask = Task { @MainActor [weak self, service] in
      let items = await service.dynamicCandidates(line: line, directory: directory)
      guard !Task.isCancelled, !items.isEmpty, let self,
        !self.isInvalidated, self.dynamicGeneration == generation,
        self.promptActive, self.tracker.isReliable, self.tracker.isCursorAtEnd,
        self.tracker.line == line, self.currentDirectory() == directory,
        self.aliases == capturedAliases, self.controls() == configuration
      else { return }
      let result = service.suggestions(line: line, directory: directory,
        sessionIdentifier: self.sessionIdentifier, controls: configuration,
        aliases: capturedAliases, dynamic: items)
      self.applyResult(result, configuration: configuration)
    }
  }

  private func cancelDynamicQuery() {
    dynamicGeneration &+= 1
    dynamicTask?.cancel()
    dynamicTask = nil
    fallbackTabTask?.cancel()
    fallbackTabTask = nil
  }

  /// 无可接受 ghost 时先查询；120ms 后仍无面板/预览才向 Shell 发送一次 Tab。
  /// 所有输入和生命周期变更都会撤销这次回退，避免在新命令上补发旧按键。
  private func queryWithFallbackTab(configuration: ControlConfiguration) -> Bool {
    guard promptActive, tracker.isReliable, tracker.isCursorAtEnd, !tracker.line.isEmpty,
      configuration.resolvedAutocompleteInlineSuggestion
        || configuration.resolvedAutocompleteCandidatePanel != .disabled
    else { return false }
    refreshNow()
    let generation = dynamicGeneration
    let line = tracker.line
    let directory = currentDirectory()
    fallbackTabTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled, let self, !self.isInvalidated,
        self.dynamicGeneration == generation, self.promptActive, self.tracker.line == line,
        self.currentDirectory() == directory, self.controls() == configuration,
        !self.panelVisible, self.inlineGhostText == nil, let terminalView = self.terminalView
      else { return }
      self.shellCompletionActive = true
      self.dismiss()
      _ = terminalView.sendAutocompleteBytes([UInt8(9)][...])
    }
    return true
  }

  /// 等待当前查询收口，供生命周期测试核对取消和迟到结果，不启动额外查询。
  func dynamicQuerySettled() async { await dynamicTask?.value }

  /// 让 8 行视窗以最小移动跟上选中项。
  ///
  /// 三步钳位同时覆盖了 ↑/↓ 的循环:末行按 ↓ 回到 0 时第一步把首行拉到 0,首行按 ↑
  /// 跳到末行时第二步把首行推到 count-8,因此不需要为 wrap 写特例分支。
  private func updateVisibleWindow() {
    firstVisibleIndex = Self.clampedFirstVisibleIndex(
      current: firstVisibleIndex,
      selected: selectedIndex,
      count: currentResult.candidates.count,
      visibleRows: TerminalAutocompleteOverlayView.maximumVisibleRows
    )
  }

  static func clampedFirstVisibleIndex(
    current: Int, selected: Int, count: Int, visibleRows: Int
  ) -> Int {
    guard count > visibleRows else { return 0 }
    var first = min(current, selected)
    first = max(first, selected - (visibleRows - 1))
    return min(max(first, 0), count - visibleRows)
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    cancelDynamicQuery()
    refreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self?.refreshNow()
    }
  }

  /// 只有用户已经输入“未知可执行文件 + 空格”后才探测 help；输入中的命令前缀不会
  /// 触发进程。每个会话每个命令最多一次，关闭本地学习时完全跳过。
  private func scheduleHelpProbeIfNeeded(configuration: ControlConfiguration) {
    if helpProbeGeneration != service.helpProbeGeneration {
      helpProbeTask?.cancel()
      probedCommands.removeAll()
      helpProbeGeneration = service.helpProbeGeneration
    }
    guard configuration.resolvedAutocompleteOnDeviceLearning,
      currentDirectory().hasPrefix("/"),
      tracker.line.contains(where: \.isWhitespace),
      let target = service.helpProbeTarget(for: tracker.line),
      probedCommands.insert(target.cacheKey).inserted
    else { return }
    helpProbeTask?.cancel()
    let generation = helpProbeGeneration
    helpProbeTask = Task { @MainActor [weak self] in
      guard let spec = await AutocompleteHelpProbe.probe(
        command: target.command, subcommandPath: target.subcommandPath),
        !Task.isCancelled, let self,
        self.service.helpProbeGeneration == generation,
        self.controls().resolvedAutocompleteOnDeviceLearning
      else { return }
      do {
        try service.installLocalSpec(
          spec, command: target.command, subcommandPath: target.subcommandPath)
        refreshNow()
      } catch {
        // 本地规格写入失败只禁用本轮探测结果；补全仍可继续使用内置规格和历史。
      }
    }
  }

  @discardableResult
  private func acceptCandidate(at index: Int) -> Bool {
    guard currentResult.candidates.indices.contains(index), let terminalView else { return false }
    // Pane 放不下面板时不能接受其中的不可见候选；仅当前真正显示的 inline 首项例外。
    guard !overlay.panelContainer.isHidden
      || (index == inlineCandidateIndex && currentResult.ghostText != nil && inlineSuggestionDisplayable)
    else { return false }
    // 原版先按Unicode scalar数量删除原始token，再写候选；普通项另加空格。
    // ghost是视觉预览，不能用它的后缀替代完整接受协议。
    guard let bytes = CompletionAcceptance.bytes(candidate: currentResult.candidates[index], line: tracker.line)
    else { return false }
    dismiss()
    return terminalView.sendAutocompleteBytes(bytes[...])
  }

  /// 在提交时保存，完成事件只清理失败参数；同一 prompt 的 OSC/输入回调只记录一次。
  private func submitForLearning(_ command: String) {
    guard !recordedCommandForPrompt else { return }
    recordedCommandForPrompt = true
    let configuration = controls()
    _ = service.submit(
      command: command, directory: currentDirectory(),
      ignorePatterns: configuration.resolvedAutocompleteHistoryIgnore,
      sessionIdentifier: sessionIdentifier,
      learningEnabled: configuration.resolvedAutocompleteOnDeviceLearning,
      skipSecrets: configuration.resolvedAutocompleteSkipSecrets)
  }

  private func finishCommand(exitStatus: Int?) {
    _ = service.commandFinished(exitStatus: exitStatus ?? 0, sessionIdentifier: sessionIdentifier)
    screenCommand = nil
  }

  /// 彻底收起补全:关面板、清候选、取消待执行的刷新。
  private func dismiss() {
    refreshTask?.cancel()
    cancelDynamicQuery()
    panelState = .hidden
    currentResult = .empty
    selectedIndex = 0
    firstVisibleIndex = 0
    render()
  }

  /// 面板里 ⇧⌫：忘记明确选中的学习候选，面板保持打开并按新结果重算，选中位置钳位。
  /// 没有面板或没有选中时放行给 Shell；选中的是规格/文件候选时吞掉按键但什么都不做，
  /// 避免 ⇧⌫ 在面板打开时意外删掉输入行的字符。
  private func forgetSelectedCandidate() -> Bool {
    guard case .open(let origin, true) = panelState,
      currentResult.candidates.indices.contains(selectedIndex)
    else { return false }
    let candidate = currentResult.candidates[selectedIndex]
    guard candidate.isLearned,
      service.forget(candidate: candidate, line: tracker.line, directory: currentDirectory())
    else { return true }
    let previousIndex = selectedIndex
    clearCandidatesForRefilter()
    refreshNow()
    if !currentResult.candidates.isEmpty, case .open = panelState {
      selectedIndex = min(previousIndex, currentResult.candidates.count - 1)
      panelState = .open(origin: origin, userSelected: true)
      updateVisibleWindow()
      render()
    }
    return true
  }

  /// 只清掉待重算的候选,**保留面板状态**。打字与退格走这条路径,面板因此能按新前缀
  /// 收窄而不是消失。debounce 窗口内候选为空,`render` 会暂时隐藏面板视图、
  /// `acceptCandidate` 因索引不存在返回 false,回车照常交给 shell。
  private func clearCandidatesForRefilter() {
    cancelDynamicQuery()
    currentResult = .empty
    selectedIndex = 0
    firstVisibleIndex = 0
  }

  /// Vi、Hint 或 Read-only 接管输入时清空候选；Prompt tracker 保留当前命令行，退出
  /// 模式后的下一次正常输入仍可从可靠状态继续刷新。
  func dismissForPaneMode() {
    dismiss()
  }

  /// 仅当终端当前可见输入行已包含本地跟踪的完整命令时，才允许显示 ghost。
  /// PTY 会混入 OSC、CSI 等非回显字节；它们可能在用户输入与真实回显之间到达，不能
  /// 以它们为依据提前读取旧 `caretFrame`。
  private func currentPromptIsEchoed() -> Bool {
    guard tracker.isReliable, tracker.isCursorAtEnd, let terminalView else { return false }
    return terminalView.visiblePromptEnds(with: tracker.line)
  }

  /// 内联预览来自一条明确候选，不合成多条历史的公共前缀。
  enum InlineSuggestion: Equatable {
    case candidate(Int)
  }

  /// 唯一候选、明确领先的候选或用户选中的候选才显示后缀。
  var inlineSuggestion: InlineSuggestion? {
    if panelVisible, hasUserSelection, currentResult.candidates.indices.contains(selectedIndex) {
      return .candidate(selectedIndex)
    }
    return currentResult.candidates.count == 1 || CompletionPresentation.leaderIsClear(currentResult.candidates)
      ? .candidate(0) : nil
  }

  private var inlineCandidateIndex: Int? {
    if case .candidate(let index) = inlineSuggestion { index } else { nil }
  }

  /// 当前 ghost 应显示的文本（不含可见性判定），测试用它核对预览内容。
  var inlineGhostText: String? {
    switch inlineSuggestion {
    case .candidate(let index): currentResult.candidates[index].appendableSuffix(from: tracker.line)
    case nil: nil
    }
  }

  /// Inline ghost 当前是否具备显示条件；接受候选与渲染必须共用同一判定，
  /// 否则会出现“接受了一个不可见 ghost”的错乱（Tab 插入用户没看到的文本）。
  private var inlineSuggestionDisplayable: Bool {
    controls().resolvedAutocompleteInlineSuggestion
      && inlineSuggestion != nil
      && !inlineDismissed
      && !awaitingInputEcho
      && currentPromptIsEchoed()
  }

  private func render() {
    guard let terminalView else { return }
    let candidate = inlineCandidateIndex.map { currentResult.candidates[$0] }
    let displayResult = AutocompleteResult(
      candidates: currentResult.candidates,
      ghostText: inlineGhostText,
      replacementStart: candidate?.replacement.start ?? currentResult.replacementStart)
    _ = overlay.render(
      result: displayResult,
      showInline: inlineSuggestionDisplayable,
      inlineHint: nil,
      showPanel: panelVisible,
      selectedIndex: selectedIndex,
      showsSelection: hasUserSelection,
      firstVisibleIndex: firstVisibleIndex,
      caretFrame: terminalView.autocompleteCaretFrame,
      font: terminalView.autocompleteFont,
      foreground: terminalView.autocompleteForegroundColor,
      // 自定义主题未来仍可能提供透明原生画布；候选浮层没有窗口材质，遇到透明色时
      // 必须回退到主题 surface，避免候选文字直接压在终端内容上。
      background: terminalView.autocompleteBackgroundColor.alphaComponent > 0.01
        ? terminalView.autocompleteBackgroundColor : AsterTheme.panel,
      accent: AsterTheme.accent
    )

  }
}

/// 轻量 AppKit overlay：ghost label 不接收鼠标，候选面板最多显示 8 行并允许点击。
/// 布局以终端 adapter 的 caretFrame 为锚点，优先显示在光标下方，空间不足时翻到上方。
@MainActor
final class TerminalAutocompleteOverlayView: NSView {
  /// 面板宽度的兜底区间。下限保证短候选不至于窄成一条，上限避免长路径把浮层
  /// 拉到整屏宽——超出的部分由行内文本截断处理。
  /// 两者都按界面字号缩放：候选文字变大后，同样的宽度区间才能装下同样多的字。
  static let minimumPanelWidth: CGFloat = InterfaceScale.length(220)
  static let maximumPanelWidth: CGFloat = InterfaceScale.length(560)
  /// 同时可见的候选行数上限。超出部分由滚动视窗承载。
  static let maximumVisibleRows = 8
  /// 描述侧栏的固定宽度。刻意用定值而不是按列表列比例:比例式宽度会让侧栏随最长
  /// 命令忽宽忽窄,用户每敲一个字符整个浮层就换一次尺寸。
  static let descriptionSidebarWidth: CGFloat = InterfaceScale.length(220)

  var onCandidateSelected: ((Int) -> Void)?
  private let ghostLabel = NSTextField(labelWithString: "")
  /// 接受键提示（剪贴板建议的「⏎ 粘贴」）。刻意独立成一个 label 而不是混进 ghost 的
  /// attributedString：提示文字用的字体与终端字体不同，混排会改变 ghostLabel 的
  /// `frame.height`，而 ghost 的 baseline 是按这个高度对齐 Metal 字形网格的。
  private let hintLabel = NSTextField(labelWithString: "")
  /// 浮层容器：圆角、描边、投影和背景都挂在它上面。
  /// `panel` 的语义因此收窄为「候选行列表列」，布局验收锁定的行宽不变量继续成立。
  let panelContainer = NSView()
  /// 候选行列表列。internal 而不是 private：布局验收要读它的 frame 与行视图，
  /// 靠截图人眼比对既不稳定也无法在 CI 上跑。
  let panel = NSStackView()
  /// 描述侧栏：只呈现当前选中项的完整描述，对齐 Otty 的 side column。
  let descriptionSidebar = AutocompleteDescriptionSidebarView()
  /// 候选超过一屏时的细滚动条。
  let scrollThumb = NSView()
  /// 保留动态色，挂入窗口或切换外观时按浮层自己的上下文重新解析 CALayer 色值。
  private var colors: (foreground: NSColor, background: NSColor, accent: NSColor)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    ghostLabel.isHidden = true
    ghostLabel.lineBreakMode = .byClipping
    // ghost 必须保持为第一个 subview：布局验收用 `subviews.first` 定位它。
    addSubview(ghostLabel)
    hintLabel.isHidden = true
    hintLabel.lineBreakMode = .byClipping
    addSubview(hintLabel)
    panel.orientation = .vertical
    panel.alignment = .width
    panel.spacing = 0
    panel.wantsLayer = true
    panelContainer.wantsLayer = true
    panelContainer.layer?.cornerRadius = 8
    panelContainer.layer?.borderWidth = 1
    panelContainer.isHidden = true
    scrollThumb.wantsLayer = true
    scrollThumb.layer?.cornerRadius = 1.5
    scrollThumb.isHidden = true
    panelContainer.addSubview(panel)
    panelContainer.addSubview(descriptionSidebar)
    panelContainer.addSubview(scrollThumb)
    addSubview(panelContainer)
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
    guard let colors else { return }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      panelContainer.layer?.backgroundColor = colors.background.withAlphaComponent(0.97).cgColor
      panelContainer.layer?.borderColor = colors.foreground.withAlphaComponent(0.18).cgColor
      panelContainer.layer?.shadowColor = colors.foreground.withAlphaComponent(0.35).cgColor
      scrollThumb.layer?.backgroundColor = colors.foreground.withAlphaComponent(0.28).cgColor
      descriptionSidebar.applyLayerColors(foreground: colors.foreground)
      for row in panel.arrangedSubviews.compactMap({ $0 as? AutocompleteCandidateRow }) {
        row.applyLayerColors(background: colors.background, accent: colors.accent)
      }
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // 判容器而不是列表列：否则点在侧栏上会穿透到终端并起选区。
    guard !panelContainer.isHidden, panelContainer.frame.contains(point) else { return nil }
    return super.hitTest(point)
  }

  /// - Returns: inline ghost 是否被完整画出（没有因 Pane 宽度不足而裁剪）。
  ///   调用方据此决定能否把它当作「用户已看见」的建议。
  @discardableResult
  func render(
    result: AutocompleteResult,
    showInline: Bool,
    inlineHint: String? = nil,
    showPanel: Bool,
    selectedIndex: Int,
    showsSelection: Bool = true,
    firstVisibleIndex: Int = 0,
    caretFrame: NSRect,
    font: NSFont,
    foreground: NSColor,
    background: NSColor,
    accent: NSColor
  ) -> Bool {
    colors = (foreground, background, accent)
    ghostLabel.font = font
    ghostLabel.textColor = foreground.withAlphaComponent(0.42)
    let ghostText = showInline ? (result.ghostText ?? "") : ""
    ghostLabel.stringValue = ghostText
    ghostLabel.isHidden = ghostText.isEmpty
    ghostLabel.sizeToFit()
    let naturalBaselineFromBottom =
      ghostLabel.frame.height - ghostLabel.firstBaselineOffsetFromTop
    let centeredBaselineFromBottom =
      naturalBaselineFromBottom + (caretFrame.height - ghostLabel.frame.height) / 2
    let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let alignedBaselineFromBottom =
      (centeredBaselineFromBottom * backingScale).rounded() / backingScale
    // Ghostty 会把 adjust-cell-height 增减的空间分到字形上下两侧；AppKit label 的
    // sizeToFit 只包含字体自然行高。按 cell 中线平移并把 baseline 对齐到设备像素，
    // 可避免补全文字始终贴住 cell 底边而比 Metal 字形低一个 Retina 像素。
    ghostLabel.frame.origin = NSPoint(
      x: caretFrame.maxX,
      y: caretFrame.minY + alignedBaselineFromBottom - naturalBaselineFromBottom
    )
    let availableGhostWidth = max(0, bounds.maxX - caretFrame.maxX)
    let inlineFits = ghostLabel.frame.width <= availableGhostWidth
    ghostLabel.frame.size.width = min(ghostLabel.frame.width, availableGhostWidth)
    layoutInlineHint(
      inlineHint, ghostVisible: !ghostLabel.isHidden && inlineFits,
      caretFrame: caretFrame, font: font, accent: accent)

    panel.arrangedSubviews.forEach {
      panel.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    guard showPanel, !result.candidates.isEmpty else {
      panelContainer.isHidden = true
      return inlineFits
    }

    // 缩小 Pane 时减少可见行数，不能把整块面板钳进输入行造成遮挡。
    let belowSpace = max(0, caretFrame.minY - bounds.minY - 8)
    let aboveSpace = max(0, bounds.maxY - caretFrame.maxY - 8)
    let rows = min(Self.maximumVisibleRows,
      Int(max(belowSpace, aboveSpace) / AutocompleteCandidateRow.height))
    guard rows > 0, bounds.width > 16 else {
      panelContainer.isHidden = true
      return inlineFits
    }
    let total = result.candidates.count
    let first = TerminalAutocompleteController.clampedFirstVisibleIndex(
      current: firstVisibleIndex, selected: selectedIndex, count: total, visibleRows: rows)
    let visible = Array(result.candidates[first..<min(total, first + rows)])

    // 宽度贴合最长的一行，而不是写死一个几乎总是撑满终端的值：候选浮层压在终端
    // 内容上，多占的每一像素都是遮挡。上下限只用来兜住极短和极长的候选。
    let hasDescription = showsSelection && visible.contains { !$0.description.isEmpty }
    let nameWidth = visible.reduce(CGFloat(0)) { widest, candidate in
      max(widest, AutocompleteCandidateRow.contentWidth(for: candidate, includingDescription: false))
    }
    let inlineWidth = visible.reduce(CGFloat(0)) { widest, candidate in
      max(widest, AutocompleteCandidateRow.contentWidth(for: candidate))
    }
    let available = max(0, bounds.width - 16)
    // 侧栏装不下时先压缩列表列，压到下限仍不够就整个放弃侧栏、退回行内描述。
    var sidebarWidth: CGFloat = hasDescription ? Self.descriptionSidebarWidth : 0
    var listWidth = min(max(nameWidth, Self.minimumPanelWidth), Self.maximumPanelWidth)
      .rounded(.up)
    if sidebarWidth > 0, listWidth + sidebarWidth > available {
      listWidth = max(Self.minimumPanelWidth, available - sidebarWidth).rounded(.up)
      if listWidth + sidebarWidth > available {
        sidebarWidth = 0
        listWidth = min(
          min(max(inlineWidth, Self.minimumPanelWidth), Self.maximumPanelWidth).rounded(.up),
          max(Self.minimumPanelWidth, available))
      }
    }
    if sidebarWidth == 0 {
      // 向上取整到整点：小数宽度会被 Auto Layout 各自对齐到设备像素，行宽和面板宽
      // 因此差出零点几个点，边框内侧露出一条毛边。
      listWidth = min(max(showsSelection ? inlineWidth : nameWidth, Self.minimumPanelWidth), Self.maximumPanelWidth)
        .rounded(.up)
    }
    listWidth = min(listWidth, max(0, available - sidebarWidth))
    let showsInlineDescription = sidebarWidth == 0 && showsSelection

    for (offset, candidate) in visible.enumerated() {
      // 点击必须回传**全集索引**：切片内偏移会在滚动后接受错误的候选。
      let index = first + offset
      let row = AutocompleteCandidateRow(
        candidate: candidate,
        selected: showsSelection && index == selectedIndex,
        showsDescription: showsInlineDescription,
        foreground: foreground,
        background: background,
        accent: accent
      ) { [weak self] in self?.onCandidateSelected?(index) }
      row.translatesAutoresizingMaskIntoConstraints = false
      // 行宽必须显式钉到列表列宽度：竖向 NSStackView 的 `.width` 对齐只保证各行彼此
      // 等宽，不保证等于面板宽度，剩下的空间会被摆到一侧——那正是候选内容整体
      // 靠右、图标位置逐行漂移的直接原因。
      NSLayoutConstraint.activate([
        row.heightAnchor.constraint(equalToConstant: AutocompleteCandidateRow.height),
        row.widthAnchor.constraint(equalToConstant: listWidth),
      ])
      panel.addArrangedSubview(row)
    }

    // 浮层浮在终端文字之上，只靠 1px 描边分不出层次；投影让它明确「盖住」而不是
    // 「混进」终端内容。阴影色跟随前景色，深浅主题下都不会变成灰雾。
    panelContainer.shadow = NSShadow()
    panelContainer.layer?.shadowOpacity = 1
    panelContainer.layer?.shadowRadius = 12
    panelContainer.layer?.shadowOffset = CGSize(width: 0, height: -2)
    panelContainer.layer?.masksToBounds = false

    let panelHeight = CGFloat(visible.count) * AutocompleteCandidateRow.height
    let panelWidth = listWidth + sidebarWidth
    let belowY = caretFrame.minY - panelHeight - 4
    let originY = belowY >= bounds.minY + 4
      ? belowY : min(bounds.maxY - panelHeight - 4, caretFrame.maxY + 4)
    panelContainer.frame = NSRect(
      x: min(max(8, caretFrame.minX), max(8, bounds.maxX - panelWidth - 8)),
      y: max(4, originY),
      width: panelWidth,
      height: panelHeight
    )
    panel.frame = NSRect(x: 0, y: 0, width: listWidth, height: panelHeight)

    if sidebarWidth > 0 {
      descriptionSidebar.isHidden = false
      descriptionSidebar.frame = NSRect(
        x: listWidth, y: 0, width: sidebarWidth, height: panelHeight)
      let selected = result.candidates.indices.contains(selectedIndex)
        ? result.candidates[selectedIndex] : visible.first
      descriptionSidebar.update(
        candidate: selected, foreground: foreground, accent: accent)
    } else {
      descriptionSidebar.isHidden = true
    }

    // 滚动条只在超出一屏时出现：细条比 NSScrollView 便宜得多，也不会引入自己的
    // 裁剪与 tracking 去破坏「行宽 == 列表列宽」这条被测试锁定的不变量。
    if total > rows {
      let thumbHeight = max(24, panelHeight * CGFloat(rows) / CGFloat(total))
      let travel = panelHeight - thumbHeight
      let progress = CGFloat(first) / CGFloat(total - rows)
      scrollThumb.isHidden = false
      scrollThumb.frame = NSRect(
        x: listWidth - 5, y: travel * (1 - progress), width: 3, height: thumbHeight)
    } else {
      scrollThumb.isHidden = true
    }
    panelContainer.isHidden = false
    applyLayerColors()
    return inlineFits
  }

  /// 把接受键提示排在 ghost 右侧。ghost 被裁、没有提示文案，或提示自己也放不下时
  /// 整条隐藏——一个半截的提示比没有提示更让人困惑。
  private func layoutInlineHint(
    _ hint: String?, ghostVisible: Bool, caretFrame: NSRect, font: NSFont, accent: NSColor
  ) {
    guard let hint, ghostVisible else {
      hintLabel.isHidden = true
      return
    }
    // 提示紧贴 ghost 文字，字号从终端字体推导而不是界面字号，不走 InterfaceScale。
    hintLabel.font = .systemFont(ofSize: max(9, font.pointSize - 2))
    hintLabel.textColor = accent.withAlphaComponent(0.75)
    hintLabel.stringValue = hint
    hintLabel.sizeToFit()
    let originX = ghostLabel.frame.maxX + 8
    hintLabel.frame.origin = NSPoint(
      x: originX,
      y: caretFrame.minY + (caretFrame.height - hintLabel.frame.height) / 2)
    hintLabel.isHidden = originX + hintLabel.frame.width > bounds.maxX
  }
}

/// 候选面板的描述侧栏：只呈现「当前选中项」的完整描述，对齐 Otty 的 side column。
///
/// 行内描述会被 `byTruncatingTail` 截断，Fig 规格里稍长一点的说明基本全丢；侧栏放在
/// 右列而不是底部条，是因为面板已有「下方放不下就翻到上方」的翻转逻辑，底部条会改变
/// 面板高度从而与翻转互相干扰，还会把行列表推离光标。
@MainActor
final class AutocompleteDescriptionSidebarView: NSView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let bodyLabel = NSTextField(labelWithString: "")
  private let separator = NSView()

  /// 创建侧栏：命令标题 + 可换行的描述正文。
  init() {
    super.init(frame: .zero)
    wantsLayer = true
    titleLabel.font = .interfaceMonospaced(ofSize: 11.5, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    bodyLabel.font = .interface(ofSize: 11)
    bodyLabel.lineBreakMode = .byWordWrapping
    bodyLabel.usesSingleLineMode = false
    bodyLabel.cell?.wraps = true
    separator.wantsLayer = true
    for view in [separator, titleLabel, bodyLabel] as [NSView] { addSubview(view) }
  }

  required init?(coder: NSCoder) { nil }

  /// 侧栏不参与鼠标交互：吞掉点击，避免穿透到终端起选区。
  override func mouseDown(with event: NSEvent) {}

  func update(candidate: AutocompleteCandidate?, foreground: NSColor, accent: NSColor) {
    titleLabel.stringValue = candidate?.displayText ?? ""
    titleLabel.textColor = foreground.withAlphaComponent(0.92)
    // 学习候选多一行按键提示：忘记历史只有这一个入口，不写出来用户无从发现。
    var body = candidate?.description ?? ""
    if candidate?.isLearned == true {
      body += (body.isEmpty ? "" : "\n\n") + L("⇧⌫ 从历史中删除")
    }
    bodyLabel.stringValue = body
    bodyLabel.textColor = foreground.withAlphaComponent(0.62)
    // 底色由前景色派生：固定灰在浅色主题里会发脏，跟随前景则永远只是「比列表列
    // 略深/略浅一点」。
    applyLayerColors(foreground: foreground)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func applyLayerColors(foreground: NSColor) {
    layer?.backgroundColor = foreground.withAlphaComponent(0.045).cgColor
    separator.layer?.backgroundColor = foreground.withAlphaComponent(0.12).cgColor
  }

  /// 手算布局：标题单行贴顶，描述正文占满其下方剩余高度。
  override func layout() {
    super.layout()
    let inset: CGFloat = 10
    separator.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
    let width = max(0, bounds.width - inset * 2)
    // 标题行高随标题字号放大，否则大字号下单行标题被裁掉下半截。
    let titleHeight = InterfaceScale.length(15)
    titleLabel.frame = NSRect(
      x: inset, y: bounds.height - 8 - titleHeight, width: width, height: titleHeight)
    bodyLabel.preferredMaxLayoutWidth = width
    let bodyHeight = max(0, titleLabel.frame.minY - 4 - 8)
    bodyLabel.frame = NSRect(x: inset, y: 8, width: width, height: bodyHeight)
    bodyLabel.cell?.truncatesLastVisibleLine = true
  }
}

@MainActor
final class AutocompleteCandidateRow: NSButton {
  /// 行高与图标槽随界面字号缩放；面板高度、可见行数都按这个值手算。
  static let height: CGFloat = InterfaceScale.length(26)
  private static let iconWidth: CGFloat = InterfaceScale.length(16)
  private static let horizontalInset: CGFloat = 10
  private static let spacing: CGFloat = 8
  private static let nameFont = NSFont.interfaceMonospaced(ofSize: 12, weight: .medium)
  private static let descriptionFont = NSFont.interface(ofSize: 11)

  private let actionClosure: () -> Void
  /// 选中行的前导标记条。测试据此确认「有确定性的定位提示，但不是整行反白」。
  private(set) var selectionBar: NSView?

  init(
    candidate: AutocompleteCandidate,
    selected: Bool,
    showsDescription: Bool = true,
    foreground: NSColor,
    background: NSColor,
    accent: NSColor,
    action: @escaping () -> Void
  ) {
    actionClosure = action
    super.init(frame: .zero)
    title = ""
    isBordered = false
    wantsLayer = true
    // 旧结论保留：候选行只有 26pt 高，整行**不透明反白**会在终端上糊成一条亮带，
    // 反而看不清选中的是哪条命令。这里改用 accent 的低透明度淡染 + 一根前导竖条：
    // 淡染由 accent 与终端底色混合而来，深浅主题下都只是「染了一层」而不是换掉底色；
    // 竖条在任意底色上都给出确定性的定位提示。
    target = self
    self.action = #selector(activate)

    if selected {
      let bar = NSView()
      bar.wantsLayer = true
      bar.layer?.cornerRadius = 1.25
      bar.translatesAutoresizingMaskIntoConstraints = false
      addSubview(bar)
      NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        bar.widthAnchor.constraint(equalToConstant: 2.5),
        bar.topAnchor.constraint(equalTo: topAnchor, constant: 3),
        bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
      ])
      selectionBar = bar
    }
    applyLayerColors(background: background, accent: accent)

    let icon = NSImageView()
    icon.image = Self.icon(for: candidate.kind)
    icon.contentTintColor = selected ? accent : foreground.withAlphaComponent(0.55)
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: Self.iconWidth).isActive = true
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let name = NSTextField(labelWithString: candidate.displayText)
    name.font = Self.nameFont
    name.textColor = selected ? accent : foreground
    name.lineBreakMode = .byTruncatingMiddle
    name.alignment = .left
    name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    // 尾部弹性视图吸收整行的剩余宽度，前面的图标和命令因此始终顶在左边。有侧栏时
    // 它是一块透明 spacer，没有侧栏时它就是行内描述——两种形态下行内元素的位置完全
    // 一致。这正是旧实现用空 `NSView()` 加 NSStackView 撑不出来的效果，那里每行都按
    // 自身内容宽度重新排，标签位置逐行漂移。
    let trailing: NSView
    if showsDescription {
      let description = NSTextField(labelWithString: candidate.description)
      description.font = Self.descriptionFont
      description.textColor = foreground.withAlphaComponent(selected ? 0.75 : 0.5)
      description.lineBreakMode = .byTruncatingTail
      description.alignment = .left
      trailing = description
    } else {
      trailing = NSView()
    }
    trailing.setContentHuggingPriority(.init(1), for: .horizontal)
    trailing.setContentCompressionResistancePriority(.init(1), for: .horizontal)

    // 不用 NSStackView：它的分布策略会把整组元素按内容宽度推向一侧，正是旧实现里
    // 「类别标签逐行漂移」的来源。这里逐条钉死约束，图标和命令永远从左边同一个
    // x 开始，尾部视图吃掉剩余宽度。
    for view in [icon, name, trailing] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    let inset = Self.horizontalInset
    let spacing = Self.spacing
    let trailingLeading = trailing.leadingAnchor.constraint(
      equalTo: name.trailingAnchor, constant: spacing)
    trailingLeading.priority = .defaultHigh
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: spacing),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
      trailingLeading,
      trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailing.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func activate() { actionClosure() }

  func applyLayerColors(background: NSColor, accent: NSColor) {
    layer?.backgroundColor = selectionBar != nil
      ? accent.withAlphaComponent(0.15).cgColor
      : background.withAlphaComponent(0.01).cgColor
    selectionBar?.layer?.backgroundColor = accent.cgColor
  }

  /// 单行在不截断时需要的宽度，供面板计算自适应宽度。
  /// `includingDescription` 为 false 时算的是「只有图标 + 命令名」的宽度，用于
  /// 描述交给侧栏承载的布局。
  static func contentWidth(
    for candidate: AutocompleteCandidate, includingDescription: Bool = true
  ) -> CGFloat {
    let name = (candidate.displayText as NSString)
      .size(withAttributes: [.font: nameFont]).width
    let description = !includingDescription || candidate.description.isEmpty
      ? 0
      : (candidate.description as NSString)
        .size(withAttributes: [.font: descriptionFont]).width + spacing
    return horizontalInset * 2 + iconWidth + spacing + name + description
  }

  /// 候选类别用图标表达，不再占一列中文标签：图标一眼可辨，也把宽度还给命令本身。
  private static func icon(for kind: AutocompleteCandidateKind) -> NSImage? {
    let symbol = switch kind {
    case .command: "terminal"
    case .subcommand: "chevron.forward"
    case .option: "switch.2"
    case .argument: "textformat"
    case .dynamicArgument: "arrow.triangle.branch"
    case .file: "doc"
    case .folder: "folder"
    case .alias: "link"
    case .snippet: "pin"
    case .learnedCommand: "clock.arrow.circlepath"
    case .readmeCommand: "book"
    case .correction: "wand.and.stars"
    case .followUp: "arrow.turn.down.right"
    case .clipboard: "doc.on.clipboard"
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: InterfaceScale.font(11), weight: .regular))
  }
}
