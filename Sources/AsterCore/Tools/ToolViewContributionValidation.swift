// 清单 `contributes.views[]` 的取值校验：规则见 docs/developer/tools-and-plugins.md「界面扩展」，错误指出字段路径。
import Foundation

extension ToolManifestValidator {
  /// 校验 `contributes` 节：视图数量、id 唯一，以及每个视图按 bar / panel 区分的字段规则。没有该节直接通过。
  func validateContributes() throws {
    guard let contributes = manifest.contributes else { return }
    let views = contributes.views
    guard !views.isEmpty else { throw failure("contributes.views", L("至少需要一个视图")) }
    guard views.count <= ToolViewContribution.maximumViews else {
      throw failure("contributes.views", countReason(ToolViewContribution.maximumViews))
    }
    var ids = Set<String>()
    for (index, view) in views.enumerated() {
      let path = "contributes.views[\(index)]"
      guard Self.isValidCode(view.id) else {
        throw failure("\(path).id", L("视图 id 只能用小写字母、数字、- 和 _，以字母或数字开头，最长 32 个字符"))
      }
      guard ids.insert(view.id).inserted else { throw failure("\(path).id", L("视图 id 重复")) }
      try validateView(view, path: path)
    }
  }

  /// 单个视图：标题、图标、挂载点与类型是否匹配，再按类型检查。
  private func validateView(_ view: ToolViewContribution, path: String) throws {
    try requiredText(view.title, field: "\(path).title", maximum: Limits.titleCharacters)
    if let icon = view.icon { try iconPath(icon, field: "\(path).icon") }
    guard view.slot.kinds.contains(view.kind) else {
      throw failure("\(path).slot", L("\(view.slot.rawValue) 不接受 \(view.kind.rawValue) 视图"))
    }
    switch view.kind {
    case .bar: try validateBar(view, path: path)
    case .panel: try validatePanel(view, path: path)
    }
  }

  /// bar：必须有脚本数据源和 exec 权限，不能有 main，高度在挂载点允许的范围内。
  private func validateBar(_ view: ToolViewContribution, path: String) throws {
    if view.main != nil { throw failure("\(path).main", L("bar 视图不能有 main")) }
    guard let source = view.source else { throw failure("\(path).source", L("bar 视图需要 source")) }
    guard source.type == "script" else { throw failure("\(path).source.type", L("目前只支持 script")) }
    guard manifest.permissions.contains(.exec) else {
      throw failure("\(path).source", L("bar 视图需要声明 exec 权限"))
    }
    try validateCommand(source.command, path: "\(path).source.command")
    if let timeout = source.timeout, !ToolViewScriptSource.timeoutRange.contains(timeout) {
      throw failure("\(path).source.timeout", rangeReason(ToolViewScriptSource.timeoutRange))
    }
    // 挂载点没有 bar 高度范围时前面的 kinds 检查已经拒绝，这里的 range 一定存在。
    if let height = view.height, let range = view.slot.barHeightRange, !range.contains(height) {
      throw failure("\(path).height", rangeReason(range))
    }
    if let refresh = view.refresh { try validateRefresh(refresh, path: "\(path).refresh") }
  }

  /// panel：必须有 .html 入口，不能有 source / refresh；高度写了就要在 80–400（只有 `sidebar.section` 会用）。
  private func validatePanel(_ view: ToolViewContribution, path: String) throws {
    if view.source != nil { throw failure("\(path).source", L("panel 视图不能有 source")) }
    if view.refresh != nil { throw failure("\(path).refresh", L("panel 视图不能有 refresh")) }
    guard let main = view.main else { throw failure("\(path).main", L("panel 视图需要 main")) }
    try relativePath(main, field: "\(path).main")
    guard main.lowercased().hasSuffix(".html") else {
      throw failure("\(path).main", L("入口必须是 .html 文件"))
    }
    if let height = view.height, !ToolViewContribution.sidebarPanelHeightRange.contains(height) {
      throw failure("\(path).height", rangeReason(ToolViewContribution.sidebarPanelHeightRange))
    }
  }

  /// 刷新策略：间隔 0（只按触发）或 5–3600 秒；触发源最多 4 个且不重复（未知取值在解码阶段已拒绝）。
  private func validateRefresh(_ refresh: ToolViewRefresh, path: String) throws {
    if let interval = refresh.interval, interval != 0, !ToolViewRefresh.intervalRange.contains(interval) {
      throw failure("\(path).interval", L("必须是 0，或在 5 到 3600 秒之间"))
    }
    guard let triggers = refresh.on else { return }
    guard triggers.count <= ToolViewRefresh.maximumTriggers else {
      throw failure("\(path).on", countReason(ToolViewRefresh.maximumTriggers))
    }
    var seen = Set<ToolViewRefreshTrigger>()
    for (index, trigger) in triggers.enumerated() where !seen.insert(trigger).inserted {
      throw failure("\(path).on[\(index)]", L("触发源重复"))
    }
  }
}
