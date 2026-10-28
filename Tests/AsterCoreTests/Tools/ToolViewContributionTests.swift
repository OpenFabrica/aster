// 清单 `contributes.views[]`：缺省值、逐层未知字段、bar / panel 各自的规则、挂载点与类型匹配、id 唯一、刷新策略边界。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolViewContribution")
struct ToolViewContributionTests {
  /// 一个合法的 bar 视图（tab.bottom），测试按需改字段。
  private func barView(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var view: [String: Any] = [
      "id": "branch", "title": "Git 分支", "kind": "bar", "slot": "tab.bottom",
      "source": ["type": "script", "command": ["bin/gitbar.sh"]],
    ]
    edit(&view)
    return view
  }

  /// 一个合法的 panel 视图（inspector.panel）。
  private func panelView(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
    var view: [String: Any] = [
      "id": "status", "title": "Git 状态", "kind": "panel", "slot": "inspector.panel", "main": "views/status.html",
    ]
    edit(&view)
    return view
  }

  /// 在文档示例清单上换入 `contributes.views`，`edit` 可继续改顶层字段。
  private func manifestData(
    views: [[String: Any]], _ edit: (inout [String: Any]) -> Void = { _ in }
  ) throws -> Data {
    try ToolManifestFixture.json { object in
      object["contributes"] = ["views": views]
      edit(&object)
    }
  }

  /// 期望带视图的清单解码失败于 `field`。
  private func expectFailure(
    _ views: [[String: Any]], field: String, _ edit: (inout [String: Any]) -> Void = { _ in },
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    expectDecodeFailure(try manifestData(views: views, edit), field: field, sourceLocation: sourceLocation)
  }

  // MARK: 解码

  /// 缺省字段保持 nil，生效值走缺省：bar 高 26、间隔 60 秒、按 cwd 触发、超时 5 秒。
  @Test func contributesViewsDecodeWithDefaults() throws {
    let manifest = try ToolManifest.decode(try manifestData(views: [barView(), panelView()]), source: .user)
    let views = manifest.views
    #expect(views.map(\.id) == ["branch", "status"])
    let bar = try #require(manifest.view(id: "branch"))
    #expect(bar.kind == .bar && bar.slot == .tabBottom)
    #expect(bar.height == nil && bar.barHeight(in: .tabBottom) == 26)
    #expect(bar.resolvedRefresh.resolvedInterval == 60)
    #expect(bar.resolvedRefresh.resolvedTriggers == [.cwd])
    #expect(bar.source?.resolvedTimeout == 5)
    let panel = try #require(manifest.view(id: "status"))
    #expect(panel.main == "views/status.html" && panel.source == nil && panel.refresh == nil)
  }

  /// 显式写出的刷新策略、高度、超时与图标原样保留。
  @Test func explicitFieldsAreKept() throws {
    let view = barView {
      $0["height"] = 24
      $0["icon"] = "icons/git.svg"
      $0["source"] = ["type": "script", "command": ["python3", "bin/bar.py"], "timeout": 8]
      $0["refresh"] = ["interval": 30, "on": ["cwd", "branch", "activePane"]]
    }
    let manifest = try ToolManifest.decode(try manifestData(views: [view]), source: .user)
    let decoded = try #require(manifest.view(id: "branch"))
    #expect(decoded.barHeight(in: .tabBottom) == 24)
    #expect(decoded.icon == "icons/git.svg")
    #expect(decoded.source?.command == ["python3", "bin/bar.py"] && decoded.source?.resolvedTimeout == 8)
    #expect(decoded.refresh == ToolViewRefresh(interval: 30, on: [.cwd, .branch, .activePane]))
  }

  /// `contributes`、视图、source、refresh 四层都拒绝拼错的字段。
  @Test func contributesUnknownKeysRejectedAtEveryLevel() throws {
    try expectFailure([barView()], field: "contributes.extra") { object in
      object["contributes"] = ["views": [barView()], "extra": 1]
    }
    try expectFailure([barView { $0["colour"] = "red" }], field: "contributes.views[0].colour")
    try expectFailure(
      [barView(), barView { $0["id"] = "two"; $0["source"] = ["type": "script", "command": ["a"], "env": [:]] }],
      field: "contributes.views[1].source.env")
    try expectFailure(
      [barView { $0["refresh"] = ["interval": 30, "every": 5] }], field: "contributes.views[0].refresh.every")
  }

  /// 视图必填字段缺失、未知 slot / kind / 触发源都报带路径的错。
  @Test func missingAndUnknownValuesReportFieldPaths() throws {
    try expectFailure([barView { $0.removeValue(forKey: "slot") }], field: "contributes.views[0].slot")
    try expectFailure([barView { $0["slot"] = "window.middle" }], field: "contributes.views[0].slot")
    try expectFailure([barView { $0["kind"] = "widget" }], field: "contributes.views[0].kind")
    try expectFailure(
      [barView { $0["refresh"] = ["on": ["cwd", "mouse"]] }], field: "contributes.views[0].refresh.on[1]")
  }

  /// `height`、`timeout`、`interval` 写成小数时报整数错误。
  @Test func integerFieldsRejectFractions() throws {
    try expectFailure([barView { $0["height"] = 24.5 }], field: "contributes.views[0].height")
    try expectFailure(
      [barView { $0["source"] = ["type": "script", "command": ["a"], "timeout": 2.5] }],
      field: "contributes.views[0].source.timeout")
    try expectFailure(
      [barView { $0["refresh"] = ["interval": 30.5] }], field: "contributes.views[0].refresh.interval")
  }

  // MARK: bar

  /// bar 必须有 script 数据源、命令合法、清单声明 exec，且不能有 main。
  @Test func barViewRequiresScriptSourceAndExecPermission() throws {
    try expectFailure([barView { $0.removeValue(forKey: "source") }], field: "contributes.views[0].source")
    try expectFailure(
      [barView { $0["source"] = ["type": "http", "command": ["a"]] }], field: "contributes.views[0].source.type")
    try expectFailure(
      [barView { $0["source"] = ["type": "script", "command": []] }], field: "contributes.views[0].source.command")
    try expectFailure(
      [barView { $0["source"] = ["type": "script", "command": ["../escape.sh"]] }],
      field: "contributes.views[0].source.command[0]")
    try expectFailure(
      [barView { $0["source"] = ["type": "script", "command": ["a"], "timeout": 31] }],
      field: "contributes.views[0].source.timeout")
    try expectFailure(
      [barView { $0["source"] = ["type": "script", "command": ["a"], "timeout": 0] }],
      field: "contributes.views[0].source.timeout")
    try expectFailure([barView { $0["main"] = "x.html" }], field: "contributes.views[0].main")
    // 没有 exec 权限（示例里的脚本功能也需要 exec，所以一并去掉 features）。
    try expectFailure([barView()], field: "contributes.views[0].source") {
      $0["permissions"] = ["clipboard.write"]
      $0.removeValue(forKey: "features")
    }
  }

  /// bar 命令的第一项可以是裸名（解释器），也可以是绝对路径。
  @Test func barCommandAcceptsBareNameAndAbsolutePath() throws {
    for command in [["python3", "bin/bar.py"], ["node", "bin/bar.js"], ["/usr/bin/env", "python3", "x.py"]] {
      let view = barView { $0["source"] = ["type": "script", "command": command] }
      _ = try ToolManifest.decode(try manifestData(views: [view]), source: .user)
    }
  }

  /// bar 高度必须在挂载点的范围内（tab.* 为 22–28）。
  @Test func barHeightMustFitSlotRange() throws {
    try expectFailure([barView { $0["height"] = 21 }], field: "contributes.views[0].height")
    try expectFailure([barView { $0["height"] = 29 }], field: "contributes.views[0].height")
    for height in [22, 26, 28] {
      _ = try ToolManifest.decode(try manifestData(views: [barView { $0["height"] = height }]), source: .user)
    }
    // window.top 固定 28。
    try expectFailure([barView { $0["slot"] = "window.top"; $0["height"] = 26 }], field: "contributes.views[0].height")
  }

  // MARK: panel

  /// panel 必须有 .html 入口、入口是插件内相对路径，且不能有 source / refresh。
  @Test func panelViewRequiresHTMLMainAndForbidsSource() throws {
    try expectFailure([panelView { $0.removeValue(forKey: "main") }], field: "contributes.views[0].main")
    try expectFailure([panelView { $0["main"] = "views/status.js" }], field: "contributes.views[0].main")
    try expectFailure([panelView { $0["main"] = "/abs/status.html" }], field: "contributes.views[0].main")
    try expectFailure([panelView { $0["main"] = "../status.html" }], field: "contributes.views[0].main")
    try expectFailure(
      [panelView { $0["source"] = ["type": "script", "command": ["a"]] }], field: "contributes.views[0].source")
    try expectFailure([panelView { $0["refresh"] = ["interval": 30] }], field: "contributes.views[0].refresh")
    try expectFailure([panelView { $0["height"] = 79 }], field: "contributes.views[0].height")
    try expectFailure([panelView { $0["height"] = 401 }], field: "contributes.views[0].height")
    _ = try ToolManifest.decode(try manifestData(views: [panelView { $0["height"] = 240 }]), source: .user)
  }

  /// 只有 panel 视图的插件不需要 `ui`，也不需要 exec。
  @Test func panelPluginDoesNotNeedUI() throws {
    let data = try manifestData(views: [panelView()]) { object in
      object.removeValue(forKey: "ui")
      object["features"] = [["code": "x", "title": "X", "keywords": ["x"], "action": ["type": "script", "command": ["bin/x.sh"]]]]
    }
    let manifest = try ToolManifest.decode(data, source: .user)
    #expect(manifest.ui == nil && manifest.views.count == 1)
    // 只有 panel 视图、没有任何功能，也没有 ui 与 exec。
    let only = try manifestData(views: [panelView()]) { object in
      object.removeValue(forKey: "ui")
      object.removeValue(forKey: "features")
      object["permissions"] = []
    }
    _ = try ToolManifest.decode(only, source: .user)
  }

  // MARK: 挂载点与唯一性

  /// 挂载点必须接受视图类型：inspector 只收 panel，window / tab / pane 只收 bar；sidebar 两者都收。
  @Test func viewSlotMustAcceptKind() throws {
    try expectFailure([barView { $0["slot"] = "inspector.panel" }], field: "contributes.views[0].slot")
    try expectFailure([panelView { $0["slot"] = "tab.top" }], field: "contributes.views[0].slot")
    try expectFailure([panelView { $0["slot"] = "window.bottom" }], field: "contributes.views[0].slot")
    // 8 个挂载点都能声明，包括本版本还没实现的。
    for slot in ToolViewSlot.allCases {
      let kind: ToolViewKind = slot.kinds.contains(.bar) ? .bar : .panel
      let view = kind == .bar ? barView { $0["slot"] = slot.rawValue } : panelView { $0["slot"] = slot.rawValue }
      _ = try ToolManifest.decode(try manifestData(views: [view]), source: .user)
    }
    _ = try ToolManifest.decode(try manifestData(views: [panelView { $0["slot"] = "sidebar.section" }]), source: .user)
  }

  /// 同一插件内视图 id 不能重复，格式同功能 code。
  @Test func viewIDsMustBeUnique() throws {
    try expectFailure([barView(), panelView { $0["id"] = "branch" }], field: "contributes.views[1].id")
    try expectFailure([barView { $0["id"] = "Bad Id" }], field: "contributes.views[0].id")
    try expectFailure([barView { $0["id"] = "" }], field: "contributes.views[0].id")
    // 视图 id 与功能 code 是两个命名空间，同名可以。
    _ = try ToolManifest.decode(try manifestData(views: [barView { $0["id"] = "decode" }]), source: .user)
  }

  /// 视图数量 1–16；标题 1–64 字符无控制字符。
  @Test func viewCountAndTitleAreBounded() throws {
    try expectFailure([], field: "contributes.views")
    let many = (0..<17).map { index in barView { $0["id"] = "v\(index)" } }
    try expectFailure(many, field: "contributes.views")
    _ = try ToolManifest.decode(try manifestData(views: Array(many.prefix(16))), source: .user)
    try expectFailure([barView { $0["title"] = "" }], field: "contributes.views[0].title")
    try expectFailure([barView { $0["title"] = String(repeating: "长", count: 65) }], field: "contributes.views[0].title")
    try expectFailure([barView { $0["title"] = "a\nb" }], field: "contributes.views[0].title")
    try expectFailure([barView { $0["icon"] = "icons/x.exe" }], field: "contributes.views[0].icon")
  }

  // MARK: 刷新策略

  /// `interval` 为 0 或 5–3600；`on` 最多 4 项且不重复。
  @Test func refreshIntervalAndTriggersAreBounded() throws {
    for interval in [1, 4, 3601, -1] {
      try expectFailure(
        [barView { $0["refresh"] = ["interval": interval] }], field: "contributes.views[0].refresh.interval")
    }
    for interval in [0, 5, 3600] {
      _ = try ToolManifest.decode(
        try manifestData(views: [barView { $0["refresh"] = ["interval": interval] }]), source: .user)
    }
    try expectFailure(
      [barView { $0["refresh"] = ["on": ["cwd", "cwd"]] }], field: "contributes.views[0].refresh.on[1]")
    try expectFailure(
      [barView { $0["refresh"] = ["on": ["cwd", "branch", "activePane", "agent", "cwd"]] }],
      field: "contributes.views[0].refresh.on")
    let all = try ToolManifest.decode(
      try manifestData(views: [barView { $0["refresh"] = ["on": ["cwd", "branch", "activePane", "agent"]] }]),
      source: .user)
    #expect(all.view(id: "branch")?.resolvedRefresh.resolvedTriggers.count == 4)
    // 空数组表示只按定时与手动刷新。
    let none = try ToolManifest.decode(
      try manifestData(views: [barView { $0["refresh"] = ["on": [String]()] }]), source: .user)
    #expect(none.view(id: "branch")?.resolvedRefresh.resolvedTriggers.isEmpty == true)
  }

  // MARK: features 与 views 的关系

  /// 只有视图、没有 `features` 的清单合法。
  @Test func manifestWithOnlyViewsIsValid() throws {
    let data = try manifestData(views: [barView()]) { $0.removeValue(forKey: "features") }
    let manifest = try ToolManifest.decode(data, source: .user)
    #expect(manifest.features.isEmpty && manifest.views.count == 1)
  }

  /// 既没有功能也没有视图时报 `features`；写了空数组同理。
  @Test func manifestWithoutFeaturesOrViewsIsRejected() throws {
    expectDecodeFailure(try ToolManifestFixture.json { $0.removeValue(forKey: "features") }, field: "features")
    expectDecodeFailure(try ToolManifestFixture.json { $0["features"] = [Any]() }, field: "features")
    // 功能超过 32 个仍然拒绝。
    let features = (0..<33).map { index in
      ["code": "f\(index)", "title": "F", "keywords": ["f"], "action": ["type": "ui"]] as [String: Any]
    }
    expectDecodeFailure(try ToolManifestFixture.json { $0["features"] = features }, field: "features")
  }

  /// 模型直接构造（内置清单的路径）时规则相同。
  @Test func modelValidationMatchesDecoding() {
    var manifest = ToolManifestFixture.manifest()
    manifest.contributes = ToolContributions(views: [
      ToolViewContribution(id: "bar", title: "条", kind: .bar, slot: .inspectorPanel)
    ])
    expectInvalid(manifest, field: "contributes.views[0].slot")
    manifest.contributes = ToolContributions(views: [
      ToolViewContribution(id: "bar", title: "条", kind: .bar, slot: .tabTop)
    ])
    expectInvalid(manifest, field: "contributes.views[0].source")
  }
}
