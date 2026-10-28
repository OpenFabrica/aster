// panel 会话缓存：同一视图复用同一会话、目录变化延后一轮再拆、上下文只在变化时推送。
// 插件不在工具中心里，会话停在「找不到插件」提示；每次推送会重新判断状态、换一个提示视图，借此观察推送次数。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
@Suite struct ToolPanelSessionCacheTests {
  /// 一个 `inspector.panel` 上的 panel 视图条目。
  private func panelEntry(
    viewID: String = "status",
    title: String = "Status",
    main: String = "views/status.html",
    isEnabled: Bool = true
  ) -> ToolViewEntry {
    ToolViewEntry(
      pluginID: "com.example.panel", pluginName: "Panel", source: .development,
      contribution: ToolViewContribution(id: viewID, title: title, kind: .panel, slot: .inspectorPanel, main: main),
      slot: .inspectorPanel, isEnabled: isEnabled, status: .ready, iconPath: nil, pluginDirectory: nil,
      permissions: [])
  }

  /// 隔离的模型与工具中心。
  private func makeCache() throws -> (ToolPanelSessionCache, ToolRuntimeSandbox, AppModel) {
    let sandbox = try ToolRuntimeSandbox()
    let suite = "ToolPanelSessionCacheTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let model = AppModel(defaults: defaults)
    return (ToolPanelSessionCache(model: model, center: sandbox.makeCenter()), sandbox, model)
  }

  /// 会话当前显示的内容视图；推送一次就会换成新的提示视图。
  private func contentView(of session: ToolSessionViewController) -> NSView? {
    session.view.subviews.first
  }

  @Test func sameEntryReusesSessionAndCarriesContext() throws {
    let (cache, sandbox, model) = try makeCache()
    defer {
      cache.teardown()
      sandbox.cleanup()
      withExtendedLifetime(model) {}
    }
    let entry = panelEntry()
    let context = ToolBarContext(workingDirectory: "/tmp/a", branch: "main", tabID: "t1", paneID: "p1")
    let first = try #require(cache.session(for: entry, context: context))
    let second = try #require(cache.session(for: entry, context: context))
    #expect(first === second)
    #expect(cache.cachedEntryIDs == [entry.id])
    #expect(first.request.view == ToolViewPlacement(contribution: entry.contribution, slot: .inspectorPanel))
    #expect(first.request.entry.feature.code == "view:status")
    #expect(first.request.input.context.workingDirectory == "/tmp/a")
    #expect(first.request.extendedContext == ["branch": "main", "tabID": "t1", "paneID": "p1"])

    // 不可挂载（用户关掉）的视图不借出会话。
    #expect(cache.session(for: panelEntry(viewID: "off", isEnabled: false), context: context) == nil)
  }

  @Test func reconcileTearsDownOnNextMainQueueTurn() async throws {
    let (cache, sandbox, model) = try makeCache()
    defer {
      cache.teardown()
      sandbox.cleanup()
      withExtendedLifetime(model) {}
    }
    let entry = panelEntry()
    let other = panelEntry(viewID: "other")
    let context = ToolBarContext()
    let session = try #require(cache.session(for: entry, context: context))
    _ = try #require(cache.session(for: other, context: context))

    // 同一轮里先消失又回来：按最近一次目录核对，不拆。
    cache.reconcile(entries: [])
    cache.reconcile(entries: [entry, other])
    #expect(await waitForToolCondition(timeout: .milliseconds(200)) { cache.cachedEntryIDs.count < 2 } == false)
    #expect(cache.session(for: entry, context: context) === session)

    // 消失：同步调用时还在，下一轮主队列才拆。
    cache.reconcile(entries: [entry])
    #expect(cache.cachedEntryIDs == [entry.id, other.id])
    #expect(await waitForToolCondition { cache.cachedEntryIDs == [entry.id] })

    // 清单里视图声明变了（入口换了）：拆掉，下次借出的是新会话。
    cache.reconcile(entries: [panelEntry(main: "views/v2.html")])
    #expect(await waitForToolCondition { cache.cachedEntryIDs.isEmpty })
    let rebuilt = try #require(cache.session(for: panelEntry(main: "views/v2.html"), context: context))
    #expect(rebuilt !== session)
    #expect(rebuilt.request.view?.contribution.main == "views/v2.html")

    // 被用户关掉：同样拆掉。
    cache.reconcile(entries: [panelEntry(main: "views/v2.html", isEnabled: false)])
    #expect(await waitForToolCondition { cache.cachedEntryIDs.isEmpty })
  }

  @Test func updateContextPushesOnlyWhenContextChanges() throws {
    let (cache, sandbox, model) = try makeCache()
    defer {
      cache.teardown()
      sandbox.cleanup()
      withExtendedLifetime(model) {}
    }
    let context = ToolBarContext(workingDirectory: "/tmp/a", branch: "main")
    let session = try #require(cache.session(for: panelEntry(), context: context))
    let initial = try #require(contentView(of: session))

    cache.updateContext(context)
    #expect(contentView(of: session) === initial, "上下文没变，不推送")

    let changed = ToolBarContext(workingDirectory: "/tmp/b", branch: "dev", paneID: "p2")
    cache.updateContext(changed)
    #expect(contentView(of: session) !== initial)
    #expect(session.request.input.context.workingDirectory == "/tmp/b")
    #expect(session.request.extendedContext == ["branch": "dev", "paneID": "p2"])

    let afterChange = contentView(of: session)
    cache.updateContext(changed)
    #expect(contentView(of: session) === afterChange)

    // 借出时带来新上下文也会推送。
    _ = cache.session(for: panelEntry(), context: ToolBarContext(workingDirectory: "/tmp/c"))
    #expect(session.request.input.context.workingDirectory == "/tmp/c")
    #expect(session.request.extendedContext.isEmpty)
  }

  @Test func teardownEndsSessionsAndStopsLending() throws {
    let (cache, sandbox, model) = try makeCache()
    defer {
      sandbox.cleanup()
      withExtendedLifetime(model) {}
    }
    let session = try #require(cache.session(for: panelEntry(), context: ToolBarContext()))
    _ = session.view
    cache.teardown()
    #expect(cache.cachedEntryIDs.isEmpty)
    #expect(session.view.subviews.isEmpty, "teardown 撤下内容")
    #expect(cache.session(for: panelEntry(), context: ToolBarContext()) == nil)
  }
}
