// 内置网页插件（Resources/tools-builtin）的清单文案只写简体中文原文；生成启动器条目与设置页摘要时，
// 把显示用的文字按界面语言翻译，和原生内置工具走同一张 Localizable.strings。用户与开发插件不经过这里。
import AsterCore
import Foundation

extension ToolManifest {
  /// 翻译显示文字后的副本：插件 `name`、`description`，每个功能的 `title`、`subtitle`，每条匹配规则的 `label`。
  /// `keywords`、id、动作、权限等不变：关键词要保留原文供搜索，其余字段决定运行行为。
  func localizedForBuiltin(_ translate: (String) -> String) -> ToolManifest {
    var copy = self
    copy.name = translate(name)
    copy.description = description.map(translate)
    copy.features = features.map { feature in
      var localized = feature
      localized.title = translate(feature.title)
      localized.subtitle = feature.subtitle.map(translate)
      localized.match = feature.match.map { $0.relabeled(translate) }
      return localized
    }
    return copy
  }
}

extension ToolMatchRule {
  /// 只换「识别到」行显示的标签，规则本身不变。
  func relabeled(_ translate: (String) -> String) -> ToolMatchRule {
    switch self {
    case .regex(var rule):
      rule.label = rule.label.map(translate)
      return .regex(rule)
    case .text(var rule):
      rule.label = rule.label.map(translate)
      return .text(rule)
    case .files(var rule):
      rule.label = rule.label.map(translate)
      return .files(rule)
    }
  }
}
