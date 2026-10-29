// Files 预览槽的模型层规则：单槽复用、原地换内容、同文件不重复、远端拒绝和预读免读盘。
import AsterCore
import Combine
import Foundation
import Testing

@testable import Aster

/// 预览槽测试夹具（固定相关用例在 FilesPreviewSlotPinningTests.swift 复用）：临时目录、若干文件和一个以文件浏览器 Pane 为活动 Pane 的标签（不启动 PTY）。
@MainActor
struct FilesPreviewSlotFixture {
  let root: URL
  let tab: TerminalTabItem

  /// - Parameter extraPanes: 按夹具根目录生成的额外 Pane，放在活动 Pane 右侧。
  init(extraPanes: (URL) -> [PaneDescriptor] = { _ in [] }) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-preview-slot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, text) in [("a.swift", "let a = 1\n"), ("b.md", "# B\n"), ("c.txt", "c\n")] {
      try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("d.png"))
    var layout = PaneLayout.leaf(PaneDescriptor(kind: .fileBrowser, workingDirectory: root.path))
    for pane in extraPanes(root) {
      layout = .split(axis: .horizontal, first: layout, second: .leaf(pane), ratio: 0.5)
    }
    tab = TerminalTabItem(title: "slot", workingDirectory: root.path, layout: layout)
  }

  /// 返回夹具目录下某个文件的 URL。
  func url(_ name: String) -> URL { root.appendingPathComponent(name).standardizedFileURL }

  /// 预读并放进预览槽。
  @discardableResult
  func show(_ name: String) throws -> PreviewSlotOutcome {
    let preload = try #require(FileDocumentPreload.load(url(name)))
    return tab.showInPreviewSlot(preload, browsingRoot: root.path)
  }

  /// 停掉运行态并删除临时目录。
  func tearDown() {
    tab.stop(immediately: true)
    try? FileManager.default.removeItem(at: root)
  }
}

@Test("连续选中文件只复用一个预览槽，活动 Pane 不变")
@MainActor
func previewSlotIsReusedAcrossSelections() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let tab = fixture.tab
  let activeBefore = tab.activePaneID
  let first = try fixture.show("a.swift")
  guard case .created(let slotID) = first else {
    Issue.record("第一次预览应新建槽，实际 \(first)")
    return
  }
  #expect(tab.layout.allPanes.count == 2)
  #expect(try fixture.show("b.md") == .retargeted(slotID))
  #expect(try fixture.show("c.txt") == .retargeted(slotID))
  #expect(tab.layout.allPanes.count == 2)
  #expect(tab.activePaneID == activeBefore)
  #expect(tab.previewSlotPaneID == slotID)
  #expect(tab.previewSlotFileURL == fixture.url("c.txt"))
  #expect(tab.runtime(for: slotID)?.isReadOnly == true)
  // 槽已经显示这个文件时不再替换。
  #expect(try fixture.show("c.txt") == .unchanged)
}

@Test("原地换内容只发 paneContentReplaced，不在原地标记外触发整树刷新")
@MainActor
func previewSlotRetargetDoesNotPublishOutsideInPlaceUpdate() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let tab = fixture.tab
  guard case .created(let slotID) = try fixture.show("a.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  var outsideInPlace = 0
  var insideInPlace = 0
  var replaced: [UUID] = []
  var cancellables: Set<AnyCancellable> = []
  tab.objectWillChange.sink { [weak tab] _ in
    if tab?.isUpdatingLayoutInPlace == true { insideInPlace += 1 } else { outsideInPlace += 1 }
  }.store(in: &cancellables)
  tab.paneContentReplaced.sink { replaced.append($0) }.store(in: &cancellables)
  let oldRuntime = tab.runtime(for: slotID)
  #expect(try fixture.show("b.md") == .retargeted(slotID))
  #expect(outsideInPlace == 0)
  #expect(insideInPlace >= 1)
  #expect(replaced == [slotID])
  #expect(tab.runtime(for: slotID) !== oldRuntime)
  #expect(tab.layout.descriptor(forPane: slotID)?.resourcePath == fixture.url("b.md").path)
  #expect(tab.layout.descriptor(forPane: slotID)?.workingDirectory == fixture.root.path)
  #expect(tab.runtime(for: slotID)?.documentText == "# B\n")
}

@Test("同一文件已在别的 Pane 打开时预览槽不动")
@MainActor
func fileOpenedElsewhereIsUnchanged() throws {
  let fixture = try FilesPreviewSlotFixture { root in
    [PaneDescriptor(kind: .editor, workingDirectory: root.path,
      resourcePath: root.appendingPathComponent("a.swift").path)]
  }
  defer { fixture.tearDown() }
  #expect(try fixture.show("a.swift") == .unchanged)
  #expect(fixture.tab.layout.allPanes.count == 2)
  #expect(fixture.tab.previewSlotPaneID == nil)
}

@Test("远端投影标签拒绝预览槽")
@MainActor
func remoteTabRejectsPreviewSlot() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  fixture.tab.remoteTabID = "x"
  #expect(try fixture.show("a.swift") == .rejected)
  #expect(fixture.tab.layout.allPanes.count == 1)
  #expect(fixture.tab.previewSlotPaneID == nil)
}

@Test("预读得到的运行态不再读盘，文件删除后仍显示预读内容")
@MainActor
func preloadBackedRuntimeDoesNotReadDisk() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let preload = try #require(FileDocumentPreload.load(fixture.url("a.swift")))
  try FileManager.default.removeItem(at: fixture.url("a.swift"))
  guard case .created(let slotID) = fixture.tab.showInPreviewSlot(
    preload, browsingRoot: fixture.root.path)
  else {
    Issue.record("预读结果应能直接建槽")
    return
  }
  let runtime = try #require(fixture.tab.runtime(for: slotID))
  #expect(runtime.documentText == "let a = 1\n")
  #expect(runtime.documentError == nil)
  #expect(runtime.preloadedPresentationKind == .sourceText)
}
