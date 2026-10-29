import Foundation
import Testing

@testable import AsterCore

/// `pane list` / `tab list` 与 MCP 列表工具共用的快照投影和表格渲染。
struct SessionLayoutListingTests {
  /// 两个窗口：w1 是焦点窗口（t1 两个 Pane，t2 一个跑着 agent 的 Pane），w2 一个标签。
  static let snapshot: SessionSnapshot = {
    let agent = AgentInfo(
      paneID: "w1:p3", tabID: "w1:t2", windowID: "w1", name: "reviewer", agent: "codex", agentStatus: .idle,
      detection: .hook, focused: true, stateChangeSeq: 1)
    return SessionSnapshot(
      windows: [
        .init(
          windowID: "w1", focused: true,
          tabs: [
            .init(
              tabID: "w1:t1", title: "build", focused: false,
              panes: [
                PaneInfo(
                  paneID: "w1:p1", tabID: "w1:t1", windowID: "w1", kind: .terminal, cwd: "/src", command: "make",
                  focused: true, running: true),
                PaneInfo(paneID: "w1:p2", tabID: "w1:t1", windowID: "w1", kind: .editor, focused: false, running: false),
              ]),
            .init(
              tabID: "w1:t2", title: nil, focused: true,
              panes: [
                PaneInfo(
                  paneID: "w1:p3", tabID: "w1:t2", windowID: "w1", kind: .terminal, cwd: "/repo", focused: true,
                  running: true, agent: agent)
              ]),
          ]),
        .init(
          windowID: "w2", focused: false,
          tabs: [
            .init(
              tabID: "w2:t1", title: "logs", focused: true,
              panes: [PaneInfo(paneID: "w2:p1", tabID: "w2:t1", windowID: "w2", kind: .terminal, focused: true, running: true)])
          ]),
      ], sequence: 7)
  }()

  @Test("tab list：全部窗口；--window 接受窗口 / 标签 / Pane ID、agent 名与 current")
  func tabs() throws {
    let all = try SessionLayoutListing.tabs(in: Self.snapshot)
    #expect(all.map(\.tabID) == ["w1:t1", "w1:t2", "w2:t1"])
    #expect(all[1] == .init(windowID: "w1", tabID: "w1:t2", selected: true, windowFocused: true, paneCount: 1))
    for selector in ["w2", "w2:t1", "w2:p1"] {
      #expect(try SessionLayoutListing.tabs(in: Self.snapshot, window: selector).map(\.tabID) == ["w2:t1"])
    }
    #expect(try SessionLayoutListing.tabs(in: Self.snapshot, window: "reviewer").count == 2)
    // current 退回焦点 Pane（w1:p3）所在窗口。
    #expect(try SessionLayoutListing.tabs(in: Self.snapshot, window: "current").map(\.windowID) == ["w1", "w1"])
    #expect(throws: AsterControlError.self) { try SessionLayoutListing.tabs(in: Self.snapshot, window: "w9") }
  }

  @Test("pane list：全部 Pane；--tab 接受标签 / Pane ID、agent 名与 current；找不到报 not_found")
  func panes() throws {
    #expect(try SessionLayoutListing.panes(in: Self.snapshot).map(\.paneID) == ["w1:p1", "w1:p2", "w1:p3", "w2:p1"])
    #expect(try SessionLayoutListing.panes(in: Self.snapshot, tab: "w1:t1").map(\.paneID) == ["w1:p1", "w1:p2"])
    #expect(try SessionLayoutListing.panes(in: Self.snapshot, tab: "w1:p2").map(\.paneID) == ["w1:p1", "w1:p2"])
    #expect(try SessionLayoutListing.panes(in: Self.snapshot, tab: "reviewer").map(\.paneID) == ["w1:p3"])
    #expect(try SessionLayoutListing.panes(in: Self.snapshot, tab: "current").map(\.paneID) == ["w1:p3"])
    do {
      _ = try SessionLayoutListing.panes(in: Self.snapshot, tab: "w1:t9")
      Issue.record("应当抛 not_found")
    } catch let error as AsterControlError {
      #expect(error.code == .notFound)
    }
    // 没有焦点窗口时 current 无从解析。
    let unfocused = SessionSnapshot(windows: [], sequence: 0)
    #expect(throws: AsterControlError.self) { try SessionLayoutListing.panes(in: unfocused, tab: "current") }
  }

  @Test("表格：* 标当前标签 / 焦点窗口 / 焦点 Pane，agent 优先于命令，空值写 -")
  func rendering() throws {
    let tabs = SessionLayoutListing.renderTabs(try SessionLayoutListing.tabs(in: Self.snapshot))
    #expect(
      tabs == """
        TAB     WINDOW  PANES  TITLE
        w1:t1   w1*     2      build
        w1:t2*  w1*     1      -
        w2:t1*  w2      1      logs
        """)
    let panes = SessionLayoutListing.renderPanes(try SessionLayoutListing.panes(in: Self.snapshot, tab: nil))
    #expect(
      panes == """
        PANE    TAB    KIND      PROCESS     CWD
        w1:p1*  w1:t1  terminal  make        /src
        w1:p2   w1:t1  editor    -           -
        w1:p3*  w1:t2  terminal  codex:idle  /repo
        w2:p1*  w2:t1  terminal  -           -
        """)
    #expect(SessionLayoutListing.renderTabs([]) == "(no tabs)")
    #expect(SessionLayoutListing.renderPanes([]) == "(no panes)")
  }

  @Test("JSON 结果用 snake_case 键，Pane 行与 session.snapshot 的 PaneInfo 同形")
  func jsonShape() throws {
    let tabs = try JSONValue(encoding: SessionLayoutListing.TabListResult(tabs: try SessionLayoutListing.tabs(in: Self.snapshot)))
    #expect(tabs["tabs"]?.arrayValue?.first?["window_focused"] == true)
    #expect(tabs["tabs"]?.arrayValue?.first?["pane_count"] == 2)
    let panes = try JSONValue(encoding: SessionLayoutListing.PaneListResult(panes: try SessionLayoutListing.panes(in: Self.snapshot)))
    #expect(panes["panes"]?.arrayValue?.first?["pane_id"] == "w1:p1")
  }
}
