// 工具面板内容区的状态切换：重置后列出工具，展开工具时高度跟工具区走，退出后回到结果列表。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 只记录高度变化的内容区 delegate。
@MainActor
private final class RecordingContentDelegate: ToolLauncherContentDelegate {
  var heightChanges = 0

  func launcherContent(
    _ content: ToolLauncherViewController, open row: ToolLauncherRow, input: ToolInput, queryText: String
  ) {}
  func launcherContentDidRequestPrefill(_ content: ToolLauncherViewController) {}
  func launcherContentDidRequestOpenAsPane(_ content: ToolLauncherViewController) {}
  func launcherContent(_ content: ToolLauncherViewController, toolQueryChanged text: String) {}
  func launcherContent(_ content: ToolLauncherViewController, toolReceivedFiles files: [String]) {}
  func launcherContentDidRequestExitTool(_ content: ToolLauncherViewController) {}
  func launcherContentDidRequestClose(_ content: ToolLauncherViewController) {}
  func launcherContentDidChangeHeight(_ content: ToolLauncherViewController, animated: Bool) {
    heightChanges += 1
  }
}

/// 什么都不做的工具宿主。
@MainActor
private final class SilentToolHost: ToolSessionHost {
  func toolSessionDidRequestClose(_ session: ToolSessionViewController) {}
  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat) {}
  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool) {}
  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool { false }
  func toolSessionOpenInPane(_ session: ToolSessionViewController) {}
  func toolSession(
    _ session: ToolSessionViewController, runInTerminal command: [String], workingDirectory: String?,
    environment: [String: String]
  ) {}
  var toolSessionWindow: NSWindow? { nil }
}

@MainActor
@Test("工具面板内容：重置后列出工具，展开工具时高度跟工具区走，退出后回到结果列表")
func toolLauncherContentSwitchesBetweenResultsAndTool() throws {
  _ = NSApplication.shared
  let content = ToolLauncherViewController()
  let delegate = RecordingContentDelegate()
  content.delegate = delegate
  // 放宽可用高度，只验证工具区高度取自工具本身（清单允许范围内）。
  content.maximumContentHeight = 2_000
  content.reset(context: ToolContext())
  #expect(!content.rows.isEmpty)
  #expect(content.rows.allSatisfy { $0.origin == .search })
  #expect(!content.isToolOpen)
  let resultsHeight = content.preferredContentHeight

  let entry = try #require(content.selectedRow).entry
  let host = SilentToolHost()
  let session = ToolCenter.shared.makeSession(
    for: ToolLaunchRequest(entry: entry, input: ToolInput(), origin: nil), host: host)
  content.presentTool(session, title: entry.feature.title, queryText: "")

  #expect(content.isToolOpen)
  #expect(session.parent === content)
  let range = ToolUIConfig.heightRange
  let toolHeight = min(max(session.preferredHeight, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
  #expect(
    content.preferredContentHeight
      == ToolLauncherViewController.searchRowHeight + 2 + ToolLauncherViewController.footerHeight + toolHeight)
  // 工具请求新高度时通知窗口控制器重排。
  content.setToolHeight(CGFloat(range.lowerBound))
  #expect(delegate.heightChanges == 1)

  session.teardown()
  content.dismissTool()
  #expect(!content.isToolOpen)
  #expect(session.parent == nil)
  #expect(content.preferredContentHeight == resultsHeight)
}
