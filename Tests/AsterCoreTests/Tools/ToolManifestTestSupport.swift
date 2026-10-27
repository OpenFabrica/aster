// 清单测试的公共夹具：一份合法的用户插件清单（模型与 JSON 两种形式）与断言辅助。
import Foundation
import Testing

@testable import AsterCore

enum ToolManifestFixture {
  /// 合法的用户插件：一个网页功能（带 regex 规则）+ 一个脚本功能。
  static func manifest() -> ToolManifest {
    ToolManifest(
      id: "com.example.jwt", name: "JWT 解析", version: "1.2.0", description: "解析 JWT", author: "Example",
      homepage: "https://example.com", icon: "icon.svg", ui: ToolUIConfig(main: "index.html", height: 420),
      permissions: [.clipboardWrite, .exec],
      features: [
        ToolFeature(
          code: "decode", title: "解析 JWT", subtitle: "header / payload", keywords: ["jwt", "token"],
          match: [.regex(ToolRegexRule(label: "解析这个 JWT", pattern: #"^eyJ[\w-]+\.[\w-]+\.[\w-]*$"#, maxLength: 8192))],
          action: .ui),
        ToolFeature(
          code: "now", title: "当前时间戳", keywords: ["now"],
          action: .script(ToolScriptAction(command: ["bin/now.sh"]))),
      ])
  }

  /// 文档里的示例清单（补上脚本动作必需的 exec 权限）。
  static let documentExample = #"""
    {
      "schemaVersion": 1,
      "id": "com.example.jwt",
      "name": "JWT 解析",
      "version": "1.2.0",
      "description": "解析 JWT 的 header 与 payload",
      "author": "Example",
      "homepage": "https://example.com",
      "icon": "icon.svg",
      "ui": { "main": "index.html", "height": 420 },
      "permissions": ["clipboard.write", "terminal.insert", "exec"],
      "network": [],
      "features": [
        {
          "code": "decode",
          "title": "解析 JWT",
          "subtitle": "header / payload / 过期时间",
          "keywords": ["jwt", "token"],
          "match": [{ "type": "regex", "label": "解析这个 JWT", "pattern": "^eyJ[\\w-]+\\.[\\w-]+\\.[\\w-]*$", "maxLength": 8192 }],
          "action": { "type": "ui" }
        },
        {
          "code": "now",
          "title": "当前时间戳",
          "keywords": ["now"],
          "action": { "type": "script", "command": ["bin/now.sh"], "output": "text" }
        }
      ]
    }
    """#

  /// 把示例清单解析成可修改的字典，交给 `edit` 改动后再序列化。
  static func json(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(documentExample.utf8)) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  /// 改第 `index` 个功能。
  static func editFeature(_ object: inout [String: Any], _ index: Int, _ edit: (inout [String: Any]) -> Void) {
    guard var features = object["features"] as? [[String: Any]] else { return }
    edit(&features[index])
    object["features"] = features
  }

  /// 改第 `index` 个功能的第 `rule` 条 match 规则。
  static func editRule(_ object: inout [String: Any], _ index: Int, _ rule: Int, _ edit: (inout [String: Any]) -> Void) {
    editFeature(&object, index) { feature in
      guard var rules = feature["match"] as? [[String: Any]] else { return }
      edit(&rules[rule])
      feature["match"] = rules
    }
  }

  /// 改第 `index` 个功能的动作。
  static func editAction(_ object: inout [String: Any], _ index: Int, _ edit: (inout [String: Any]) -> Void) {
    editFeature(&object, index) { feature in
      guard var action = feature["action"] as? [String: Any] else { return }
      edit(&action)
      feature["action"] = action
    }
  }
}

/// 期望清单数据解码失败，且错误指向 `field`。
func expectDecodeFailure(
  _ data: Data,
  source: ToolPluginSource = .user,
  field: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  do {
    _ = try ToolManifest.decode(data, source: source)
    Issue.record("应当解码失败于 \(field)", sourceLocation: sourceLocation)
  } catch let error as ToolManifestError {
    #expect(error.field == field, "\(error.reason)", sourceLocation: sourceLocation)
  } catch {
    Issue.record("意外的错误类型：\(error)", sourceLocation: sourceLocation)
  }
}

/// 期望清单模型校验失败，且错误指向 `field`。
func expectInvalid(
  _ manifest: ToolManifest,
  source: ToolPluginSource = .user,
  field: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  do {
    try manifest.validate(source: source)
    Issue.record("应当校验失败于 \(field)", sourceLocation: sourceLocation)
  } catch let error as ToolManifestError {
    #expect(error.field == field, "\(error.reason)", sourceLocation: sourceLocation)
  } catch {
    Issue.record("意外的错误类型：\(error)", sourceLocation: sourceLocation)
  }
}
