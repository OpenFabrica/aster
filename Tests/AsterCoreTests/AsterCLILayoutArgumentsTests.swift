import Foundation
import Testing

@testable import AsterCore

/// `aster pane close|split|list` 与 `aster tab new|close|focus|rename|list` 的参数解析与分组帮助。
struct AsterCLILayoutArgumentsTests {
  private func parse(_ argv: [String]) throws -> AsterCLIArguments {
    try AsterCLIArguments.parse(argv)
  }

  private func command(_ argv: [String]) throws -> AsterCLICommand {
    try parse(argv).command
  }

  @Test("pane close 必须显式给目标；pane split 缺省拆调用者的 Pane 并默认向右")
  func paneCloseAndSplit() throws {
    #expect(try command(["pane", "close", "w1:p3"]) == .paneClose(PaneCloseParams(pane: "w1:p3")))
    #expect(try command(["pane", "close", "--pane", "w1:p3"]) == .paneClose(PaneCloseParams(pane: "w1:p3")))
    #expect(try command(["pane", "close", "--current"]) == .paneClose(PaneCloseParams(pane: "current")))
    #expect(throws: AsterCLIArgumentError("pane close 需要 <pane>、--pane <id> 或 --current")) {
      try command(["pane", "close"])
    }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "close", "w1:p1", "w1:p2"]) }

    #expect(try command(["pane", "split"]) == .paneSplit(pane: nil, direction: .right))
    #expect(
      try command(["pane", "split", "w1:p2", "--direction", "down"])
        == .paneSplit(pane: "w1:p2", direction: .down))
    #expect(try command(["pane", "split", "--current", "--direction=left"]) == .paneSplit(pane: "current", direction: .left))
    #expect(throws: AsterCLIArgumentError("--direction 只支持 right | left | down | up")) {
      try command(["pane", "split", "--direction", "sideways"])
    }
  }

  @Test("tab new / close / focus：目标与选项")
  func tabNewCloseFocus() throws {
    #expect(try command(["tab", "new"]) == .tabNew(window: nil, cwd: nil))
    #expect(
      try command(["tab", "new", "--cwd", "src", "--window", "w2"]) == .tabNew(window: "w2", cwd: "src"))
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "new", "/tmp"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "new", "--cwd", ""]) }

    #expect(try command(["tab", "close", "w1:t2"]) == .tabClose(TabTargetParams(tab: "w1:t2")))
    #expect(try command(["tab", "close", "--current"]) == .tabClose(TabTargetParams(tab: "current")))
    #expect(try command(["tab", "focus", "w1:p5"]) == .tabFocus(TabTargetParams(tab: "w1:p5")))
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "close"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "focus", "w1:t1", "w1:t2"]) }
  }

  @Test("tab rename：<tab> 与 --current、<title> 与 --clear 两两互斥")
  func tabRename() throws {
    #expect(
      try command(["tab", "rename", "w1:t2", "构建 日志"])
        == .tabRename(TabRenameParams(tab: "w1:t2", title: "构建 日志")))
    #expect(
      try command(["tab", "rename", "--current", "api"])
        == .tabRename(TabRenameParams(tab: "current", title: "api")))
    #expect(
      try command(["tab", "rename", "w1:t2", "--clear"])
        == .tabRename(TabRenameParams(tab: "w1:t2", title: nil)))
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "rename", "w1:t2"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "rename", "--current"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "rename", "w1:t2", "a", "--clear"]) }
    #expect(throws: AsterCLIArgumentError.self) {
      try command(["tab", "rename", "w1:t2", String(repeating: "长", count: 100)])
    }
  }

  @Test("tab 组：新子命令走新语法并认尾部 --json，tab badge 仍回落到旧解析器")
  func tabGroupRouting() throws {
    let parsed = try parse(["tab", "new", "--json"])
    #expect(parsed.format == .json)
    #expect(parsed.command == .tabNew(window: nil, cwd: nil))
    #expect(try command(["tab", "badge", "3"]) == .legacy(["tab", "badge", "3"]))
    #expect(try command(["tab"]) == .groupHelp(.tab))
  }

  @Test("pane / tab 分组帮助：组名、-h、--help、help 与新子命令后的 -h；旧子命令与 -- 之后不拦截")
  func groupHelp() throws {
    for argv in [["pane", "-h"], ["pane", "--help"], ["pane", "help"], ["pane", "list", "-h"], ["pane", "read", "w1:p1", "--help"]] {
      #expect(try command(argv) == .groupHelp(.pane))
    }
    for argv in [["tab", "-h"], ["tab", "--help"], ["tab", "list", "--help"], ["tab", "rename", "-h"]] {
      #expect(try command(argv) == .groupHelp(.tab))
    }
    #expect(try parse(["--json", "pane", "-h"]).command == .groupHelp(.pane))
    #expect(try command(["pane", "run", "-h"]) == .legacy(["pane", "run", "-h"]))
    #expect(try command(["tab", "badge", "-h"]) == .legacy(["tab", "badge", "-h"]))
    #expect(try command(["pane", "send-text", "--", "-h"]) == .legacy(["pane", "send-text", "--", "-h"]))
    #expect(try parse(["pane", "list", "-h"]).requiresAsterEnv == false)

    let pane = AsterCLIArguments.usage(for: .pane)
    #expect(pane.contains("pane list [--tab <tab>|--current]"))
    #expect(!pane.contains("tab new"))
    let tab = AsterCLIArguments.usage(for: .tab)
    #expect(tab.contains("tab list [--window <id>|--current]"))
    #expect(!tab.contains("pane read"))
    // 总帮助与分组帮助共用同一份用法文本。
    #expect(AsterCLIArguments.usage.contains(AsterCLIArguments.paneUsage))
    #expect(AsterCLIArguments.usage.contains(AsterCLIArguments.tabUsage))
  }

  @Test("pane list / tab list：范围选项、--current 与非法输入；只读命令不要求 ASTER_ENV")
  func listCommands() throws {
    #expect(try command(["pane", "list"]) == .paneList(tab: nil))
    #expect(try command(["pane", "list", "--tab", "w1:t2"]) == .paneList(tab: "w1:t2"))
    #expect(try command(["pane", "list", "--tab=reviewer"]) == .paneList(tab: "reviewer"))
    #expect(try command(["pane", "list", "--current"]) == .paneList(tab: "current"))
    let json = try parse(["pane", "list", "--json"])
    #expect(json.format == .json && json.command == .paneList(tab: nil) && !json.requiresAsterEnv)
    #expect(throws: AsterCLIArgumentError("--current 与 --tab 不能同时给出")) {
      try command(["pane", "list", "--current", "--tab", "w1:t1"])
    }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "list", "w1:t1"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "list", "--tab", "p_\(UUID().uuidString)"]) }

    #expect(try command(["tab", "list"]) == .tabList(window: nil))
    #expect(try command(["tab", "list", "--window", "w2"]) == .tabList(window: "w2"))
    #expect(try command(["tab", "list", "--current"]) == .tabList(window: "current"))
    #expect(try parse(["tab", "list"]).requiresAsterEnv == false)
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "list", "--window", "W 1"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["tab", "list", "--all"]) }
  }

  @Test("会启动或结束进程的结构命令只对 Aster 内进程开放；focus / rename 不设限")
  func environmentRequirement() throws {
    #expect(try parse(["pane", "close", "w1:p2"]).requiresAsterEnv)
    #expect(try parse(["pane", "split"]).requiresAsterEnv)
    #expect(try parse(["tab", "new"]).requiresAsterEnv)
    #expect(try parse(["tab", "close", "w1:t2"]).requiresAsterEnv)
    #expect(!(try parse(["tab", "focus", "w1:t2"]).requiresAsterEnv))
    #expect(!(try parse(["tab", "rename", "w1:t2", "x"]).requiresAsterEnv))
  }

  @Test("写门禁分类：关闭 / 拆分 / 新建算写，focus / rename 不算")
  func writeClassification() {
    for method in [AsterControlMethod.paneClose, .paneSplit, .tabNew, .tabClose] {
      #expect(method.isWrite)
    }
    #expect(!AsterControlMethod.tabFocus.isWrite)
    #expect(!AsterControlMethod.tabRename.isWrite)
  }

  @Test("参数校验：cwd 必须是绝对路径，结果按 snake_case 编码")
  func paramsAndResultCoding() throws {
    #expect(throws: AsterControlError.self) { try TabNewParams(cwd: "relative/dir").validate() }
    try TabNewParams(window: "w1:p1", cwd: "/tmp").validate()
    #expect(throws: AsterControlError.self) { try PaneCloseParams(pane: "").validate() }
    let split = try JSONValue.object(["pane": "w1:p1"]).decoded(as: PaneSplitParams.self)
    #expect(split.direction == .right)

    let encoded = try JSONValue(
      encoding: LayoutActionResult(windowID: "w1", tabID: "w1:t2", paneID: "w1:p4", closedTab: true))
    #expect(encoded["window_id"]?.stringValue == "w1")
    #expect(encoded["tab_id"]?.stringValue == "w1:t2")
    #expect(encoded["pane_id"]?.stringValue == "w1:p4")
    #expect(encoded["closed_tab"]?.boolValue == true)
    #expect(encoded["ok"]?.boolValue == true)
  }
}
