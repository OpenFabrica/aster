// 文件 Pane 进入与恢复时不能继续展示原 Shell 的 OSC 标题。
import AppKit
import AsterCore
import Testing
@testable import Aster

@Test("用文件替换终端后，自动标题使用文件名并保留用户命名")
@MainActor
func filePaneReplacementClearsPreviousShellTitle() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
  try "file title".write(to: file, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: file) }
  let tab = TerminalTabItem(title: "shell", workingDirectory: file.deletingLastPathComponent().path)
  defer { tab.stop(immediately: true) }
  tab.applyProgramTitle(code: 2, text: "previous shell")
  #expect(tab.replaceActivePane(with: .editor, resourceURL: file))
  #expect(tab.windowTitle == file.lastPathComponent)
  #expect(tab.displayTitle == file.lastPathComponent)
  #expect(tab.activeFileTitle == file.lastPathComponent)
  tab.setTabTitleOverride(.name("My file"))
  #expect(tab.replaceActivePane(with: .preview, resourceURL: file))
  #expect(tab.displayTitle == "My file")
  #expect(tab.activeFileTitle == "My file")
}

@Test("恢复旧文件布局时清除继承的程序标题")
@MainActor
func filePaneRestorationUsesResourceTitle() {
  let resource = PaneDescriptor(kind: .preview, workingDirectory: "/tmp", resourcePath: "/tmp/document.md")
  var oldTitle = TerminalTitleState(fallback: "shell")
  oldTitle.applyOSC(code: 2, text: "old shell cwd")
  let tab = TerminalTabItem(title: "old shell cwd", workingDirectory: "/tmp", layout: .leaf(resource), titleState: oldTitle)
  defer { tab.stop(immediately: true) }
  #expect(tab.windowTitle == "document.md")
  #expect(tab.displayTitle == "document.md")
}

@Test("文件标题胶囊显示资源名，切回终端恢复目录")
@MainActor
func fileTitleCapsuleRestoresDirectory() {
  let button = WorkspaceTitleButton(programTitle: "shell", workingDirectory: "/tmp/workspace",
    foregroundColor: .labelColor, backgroundColor: nil) { _ in }
  button.resourceTitle = "document.md"
  #expect(button.title == "document.md ⋯")
  button.resourceTitle = nil
  #expect(button.title == "/tmp/workspace ⋯")
}
