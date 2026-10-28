// 便笺的协调者：持有全部便笺与它们的窗口，负责新建、显示、隐藏、删除与改动保存。
// 便笺窗口不属于任何工作区，关闭窗口只是隐藏，内容留着；启动时重新打开上次开着的便笺。
import AppKit
import AsterCore
import Combine

/// 便笺中心。只在主线程使用；App 用 `shared`，测试用临时文件另建一个。
@MainActor
final class StickyNoteCenter {
  static let shared = StickyNoteCenter(
    store: StickyNoteStore(
      fileURL: AsterAppIdentity.current.applicationSupportDirectory().appendingPathComponent("sticky-notes.json")))

  /// 新便笺的默认尺寸（点）。
  static let defaultSize = NSSize(width: 260, height: 240)

  private let store: StickyNoteStore
  private var windows: [UUID: StickyNoteWindowController] = [:]
  private let changeSubject = PassthroughSubject<Void, Never>()

  /// 「发送到当前 Pane」的目标工作区，App 启动时注入。便笺窗口拿着键盘时 key window 不是工作区，
  /// 所以由 App 按窗口前后顺序找最前面的工作区窗口；没有注入（测试）时发送会提示没有终端。
  var workspaceProvider: (() -> AppModel?)?

  /// 绑定存储；不会自动打开窗口，启动时调用 `restoreOpenNotes()`。
  init(store: StickyNoteStore) {
    self.store = store
  }

  /// 便笺列表、内容、颜色或开关变化时发出。
  var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }

  /// 全部便笺，最近改过的在前。
  var notes: [StickyNote] {
    store.file.notes.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  /// 按 id 取便笺。
  func note(id: UUID) -> StickyNote? {
    store.file.notes.first { $0.id == id }
  }

  /// 窗口正开着的便笺 id（测试用）。
  var openNoteIDs: Set<UUID> { Set(windows.keys) }

  // MARK: - 打开与关闭

  /// 启动时重新打开上次开着的便笺，不抢焦点。
  func restoreOpenNotes() {
    for note in store.file.notes where note.isOpen {
      showWindow(for: note, activate: false)
    }
  }

  /// 新建便笺并打开、聚焦。颜色沿用最近改过的那张，和「便笺」App 一样一组颜色连着用。
  @discardableResult
  func createNote(text: String = "", activate: Bool = true) -> StickyNote {
    let note = StickyNote(
      text: StickyNote.clampedText(text), color: notes.first?.color ?? .yellow,
      frame: nextFrame().map { StickyNoteFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
    store.update { $0.notes.append(note) }
    showWindow(for: note, activate: activate)
    changeSubject.send()
    return note
  }

  /// 显示一张便笺并提到最前（隐藏的重新打开）。
  func show(id: UUID) {
    guard let note = note(id: id) else { return }
    if !note.isOpen { mutate(id, touch: false) { $0.isOpen = true } }
    showWindow(for: note, activate: true)
  }

  /// 打开全部便笺。
  func showAll() {
    let hidden = store.file.notes.filter { !$0.isOpen }.map(\.id)
    for id in hidden { mutate(id, touch: false) { $0.isOpen = true } }
    for note in store.file.notes { showWindow(for: note, activate: false) }
    NSApp.activate()
    if let first = notes.first { windows[first.id]?.window?.makeKeyAndOrderFront(nil) }
  }

  /// 收起全部便笺（内容保留）。
  func hideAll() {
    for controller in Array(windows.values) { controller.window?.close() }
  }

  /// 删除便笺：关窗口并从文件里移除。
  func delete(id: UUID) {
    if let controller = windows.removeValue(forKey: id) { controller.closeWithoutSaving() }
    store.update { $0.notes.removeAll { $0.id == id } }
    changeSubject.send()
  }

  /// App 退出前写出最后的改动。
  func flush() {
    for controller in windows.values { controller.commitPendingFrame() }
    store.flush()
  }

  // MARK: - 窗口回调

  /// 正文或格式变了。`richText` 是整篇的 RTF；没有内容时为 nil。
  func noteTextDidChange(id: UUID, text: String, richText: Data? = nil) {
    let clamped = StickyNote.clampedText(text)
    let rich = richText.flatMap(StickyNote.acceptedRichText)
    guard let current = note(id: id), current.text != clamped || current.richText != rich else { return }
    mutate(id) {
      $0.text = clamped
      $0.richText = rich
    }
  }

  /// 换颜色。
  func setColor(_ color: StickyNoteColor, id: UUID) {
    mutate(id) { $0.color = color }
    windows[id]?.apply(color: color)
  }

  /// 切换浮在最前面。
  func setFloatsOnTop(_ floats: Bool, id: UUID) {
    mutate(id, touch: false) { $0.floatsOnTop = floats }
    windows[id]?.apply(floatsOnTop: floats)
  }

  /// 切换半透明。
  func setTranslucent(_ translucent: Bool, id: UUID) {
    mutate(id, touch: false) { $0.isTranslucent = translucent }
    windows[id]?.apply(translucent: translucent)
  }

  /// 折叠或展开（窗口自己已经改好大小，这里只记状态）。
  func setCollapsed(_ collapsed: Bool, id: UUID) {
    mutate(id, touch: false) { $0.isCollapsed = collapsed }
  }

  /// 窗口移动或改大小后记下位置；不算修改，不改变列表顺序。
  func noteFrameDidChange(id: UUID, frame: NSRect) {
    let value = StickyNoteFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    guard note(id: id)?.frame != value else { return }
    store.update { file in
      guard let index = file.notes.firstIndex(where: { $0.id == id }) else { return }
      file.notes[index].frame = value
    }
  }

  /// 用户关了便笺窗口：只是隐藏，内容留着。
  func noteWindowDidClose(id: UUID) {
    // 回调发自这个窗口控制器自己，留它到下一轮再释放。
    let controller = windows.removeValue(forKey: id)
    DispatchQueue.main.async { _ = controller }
    mutate(id, touch: false) { $0.isOpen = false }
  }

  // MARK: - 内部

  /// 改一张便笺并保存；`touch` 为 true 时更新修改时间（列表按它排序）。
  private func mutate(_ id: UUID, touch: Bool = true, _ change: (inout StickyNote) -> Void) {
    guard let index = store.file.notes.firstIndex(where: { $0.id == id }) else { return }
    var note = store.file.notes[index]
    change(&note)
    if touch { note.modifiedAt = Date() }
    guard note != store.file.notes[index] else { return }
    store.update { $0.notes[index] = note }
    changeSubject.send()
  }

  /// 便笺已有窗口就提到前面，否则新建窗口。
  private func showWindow(for note: StickyNote, activate: Bool) {
    let controller = windows[note.id] ?? {
      let created = StickyNoteWindowController(note: note, center: self)
      windows[note.id] = created
      return created
    }()
    controller.present(activate: activate)
  }

  /// 新便笺的位置：最近一张开着的便笺右下方错开一点；没有时放在鼠标所在屏幕的右上角。
  private func nextFrame() -> NSRect? {
    let size = Self.defaultSize
    if let last = notes.lazy.compactMap({ self.windows[$0.id]?.window?.frame }).first {
      let frame = NSRect(x: last.minX + 24, y: last.minY - 24, width: size.width, height: size.height)
      if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return frame }
    }
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return nil }
    return NSRect(
      x: visible.maxX - size.width - 40, y: visible.maxY - size.height - 40, width: size.width, height: size.height)
  }
}
