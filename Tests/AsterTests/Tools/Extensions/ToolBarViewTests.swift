// 原生 bar：放不下的项目收进「…」菜单、全空时整条隐藏且高度归零、失败段显示错误摘要并可点重跑、
// 按钮跨刷新复用、运行超过 1 s 才出 spinner。
import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
@Suite("界面扩展：原生 bar 视图")
struct ToolBarViewTests {
  private func segment(
    _ id: String = "p/view:bar", items: [ToolBarItem], runningSince: Date? = nil
  ) -> ToolBarSegment {
    ToolBarSegment(id: id, pluginName: "Test", iconPath: nil, content: .items(items), runningSince: runningSince)
  }

  private func makeBar(width: CGFloat) -> ToolBarView {
    let bar = ToolBarView(slot: .tabBottom, height: 26)
    bar.translatesAutoresizingMaskIntoConstraints = true
    bar.frame = NSRect(x: 0, y: 0, width: width, height: 26)
    return bar
  }

  @Test("总宽放不下时从第一个放不下的项目起收进「…」菜单，选菜单项等同点击")
  func overflowItemsMoveIntoMenu() {
    let bar = makeBar(width: 200)
    var clicked: [String] = []
    bar.onItem = { _, item in clicked.append(item.text ?? "") }
    let items = (0..<10).map { ToolBarItem(text: "item \($0)", action: .refresh) }
    bar.apply(segments: [segment(items: items)])
    bar.layoutSubtreeIfNeeded()
    #expect(!bar.isHidden)
    #expect(bar.isOverflowVisible)
    #expect(!bar.overflowedButtons.isEmpty)
    #expect(bar.visibleButtons.count + bar.overflowedButtons.count == 10)
    #expect(bar.visibleButtons.allSatisfy { $0.frame.maxX <= 200 - 8 })
    let menu = bar.makeOverflowMenu()
    #expect(menu.items.count == bar.overflowedButtons.count)
    #expect(menu.items.first?.title == "item \(bar.visibleButtons.count)")
    let first = menu.items[0]
    if let action = first.action { NSApp.sendAction(action, to: first.target, from: first) }
    #expect(clicked == ["item \(bar.visibleButtons.count)"])

    // 加宽后全部放得下，「…」消失。
    bar.frame.size.width = 2_000
    bar.layoutSubtreeIfNeeded()
    #expect(!bar.isOverflowVisible)
    #expect(bar.visibleButtons.count == 10)
  }

  @Test("全部段都为空时整条隐藏且高度归零；有项目时恢复条高")
  func barHidesWhenAllSegmentsEmpty() {
    let bar = ToolBarView(slot: .tabBottom, height: 24)
    let height = bar.constraints.first { $0.firstAttribute == .height && $0.firstItem === bar }
    bar.apply(segments: [segment(items: []), segment("q/view:other", items: [])])
    #expect(bar.isHidden)
    #expect(height?.constant == 0)
    bar.apply(segments: [segment(items: []), segment("q/view:other", items: [ToolBarItem(text: "main")])])
    #expect(!bar.isHidden)
    #expect(height?.constant == InterfaceScale.length(24))
    // 系统里不存在的符号且没有文字：这一项不占位置，整条仍按空处理。
    bar.apply(segments: [segment(items: [ToolBarItem(symbol: "no.such.symbol.aster")])])
    #expect(bar.isHidden)
  }

  @Test("失败段显示插件图标 + 警告三角，tooltip 是错误摘要，点击重跑")
  func failureSegmentShowsStderrTooltip() throws {
    let bar = makeBar(width: 400)
    var retried: [String] = []
    bar.onRetry = { retried.append($0) }
    bar.apply(segments: [
      ToolBarSegment(
        id: "p/view:bar", pluginName: "Test", iconPath: nil, content: .failed("git: not a repository"),
        runningSince: nil)
    ])
    bar.layoutSubtreeIfNeeded()
    let button = try #require(bar.visibleButtons.first)
    #expect(button.toolTip?.contains("git: not a repository") == true)
    #expect(button.content == .failure(message: "git: not a repository", iconPath: nil))
    #expect(button.accessibilityRole() == .button)
    button.onPress?()
    #expect(retried == ["p/view:bar"])
  }

  @Test("同 id 的项目跨刷新复用同一个按钮；submit 项的 tooltip 写出要执行的命令")
  func buttonsAreReusedAcrossApply() throws {
    let bar = makeBar(width: 400)
    let submit = ToolBarItem(id: "push", text: "↑2", tooltip: "推送", action: .terminal(text: "git push", mode: .submit))
    bar.apply(segments: [segment(items: [submit])])
    let first = try #require(bar.visibleButtons.first)
    #expect(first.toolTip?.contains("git push") == true)
    #expect(first.toolTip?.hasPrefix("推送") == true)
    bar.apply(segments: [segment(items: [ToolBarItem(id: "push", text: "↑3")])])
    #expect(bar.visibleButtons.first === first)
  }

  @Test("运行不到 1 s 不显示 spinner，超过 1 s 才显示")
  func spinnerAppearsAfterOneSecond() {
    let bar = makeBar(width: 400)
    let start = Date(timeIntervalSince1970: 1_000)
    var now = start.addingTimeInterval(0.5)
    bar.now = { now }
    bar.apply(segments: [segment(items: [ToolBarItem(text: "main")], runningSince: start)])
    bar.layoutSubtreeIfNeeded()
    let spinners = { bar.subviews.compactMap { $0 as? NSProgressIndicator }.filter { !$0.isHidden } }
    #expect(spinners().isEmpty)
    now = start.addingTimeInterval(1.5)
    bar.needsLayout = true
    bar.layoutSubtreeIfNeeded()
    #expect(spinners().count == 1)
  }
}
