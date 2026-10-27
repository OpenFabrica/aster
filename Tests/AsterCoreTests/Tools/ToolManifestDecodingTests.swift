// 清单严格解码：文档示例可用、每一层拒绝未知字段、类型错误给出精确字段路径、文件级错误。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolManifestDecoding")
struct ToolManifestDecodingTests {
  typealias Fixture = ToolManifestFixture

  /// 文档示例能解码，缺省值按约定补齐。
  @Test func documentExampleDecodesWithDefaults() throws {
    let manifest = try ToolManifest.decode(try Fixture.json(), source: .user)
    #expect(manifest.id == "com.example.jwt")
    #expect(manifest.resolvedUIHeight == 420)
    #expect(manifest.features.count == 2)
    #expect(manifest.features[1].match.isEmpty)
    guard case .script(let script) = manifest.features[1].action else {
      Issue.record("第二个功能应当是脚本动作")
      return
    }
    #expect(script.stdin == .text)
    #expect(script.resolvedTimeout == ScriptToolProtocol.defaultTimeout)
  }

  /// 编码后再严格解码得到同一份清单：编码只写已知字段。
  @Test func encodedManifestRoundTrips() throws {
    var manifest = Fixture.manifest()
    manifest.features[0].match.append(.files(ToolFilesRule(label: "图片", fileType: .file, extensions: ["png"])))
    manifest.features[0].match.append(.text(ToolTextRule(exclude: "^\\s*$", maxLength: 100)))
    let data = try JSONEncoder().encode(manifest)
    #expect(try ToolManifest.decode(data, source: .user) == manifest)
  }

  /// 每一层的未知字段都被拒绝，字段路径指到具体的键。
  @Test func unknownFieldsAreRejectedAtEveryLevel() throws {
    expectDecodeFailure(try Fixture.json { $0["extra"] = 1 }, field: "extra")
    expectDecodeFailure(
      try Fixture.json { $0["ui"] = ["main": "index.html", "width": 300] }, field: "ui.width")
    expectDecodeFailure(
      try Fixture.json { Fixture.editFeature(&$0, 1) { $0["hidden"] = true } }, field: "features[1].hidden")
    expectDecodeFailure(
      try Fixture.json { Fixture.editRule(&$0, 0, 0) { $0["exclude"] = "x" } },
      field: "features[0].match[0].exclude")
    expectDecodeFailure(
      try Fixture.json { Fixture.editRule(&$0, 0, 0) { $0 = ["type": "text", "pattern": "x"] } },
      field: "features[0].match[0].pattern")
    expectDecodeFailure(
      try Fixture.json { Fixture.editRule(&$0, 0, 0) { $0 = ["type": "files", "maxLength": 3] } },
      field: "features[0].match[0].maxLength")
    expectDecodeFailure(
      try Fixture.json { Fixture.editAction(&$0, 0) { $0["command"] = ["x"] } }, field: "features[0].action.command")
    expectDecodeFailure(
      try Fixture.json { Fixture.editAction(&$0, 1) { $0["handler"] = "json" } }, field: "features[1].action.handler")
    expectDecodeFailure(
      try Fixture.json { Fixture.editAction(&$0, 1) { $0 = ["type": "builtin", "handler": "json", "output": "text"] } },
      source: .builtin, field: "features[1].action.output")
  }

  /// 缺字段、类型不对、取值不认识时，错误指出精确路径。
  @Test func typeErrorsReportFieldPaths() throws {
    expectDecodeFailure(try Fixture.json { $0["schemaVersion"] = "1" }, field: "schemaVersion")
    expectDecodeFailure(try Fixture.json { $0.removeValue(forKey: "id") }, field: "id")
    expectDecodeFailure(try Fixture.json { $0["name"] = NSNull() }, field: "name")
    expectDecodeFailure(try Fixture.json { $0["permissions"] = ["exec", "camera"] }, field: "permissions[1]")
    expectDecodeFailure(try Fixture.json { $0["ui"] = ["main": "index.html", "height": 1.5] }, field: "ui.height")
    expectDecodeFailure(try Fixture.json { $0["schemaVersion"] = 1e30 }, field: "schemaVersion")
    expectDecodeFailure(try Fixture.json { $0["schemaVersion"] = true }, field: "schemaVersion")
    expectDecodeFailure(
      try Fixture.json { Fixture.editRule(&$0, 0, 0) { $0["maxLength"] = 2.5 } }, field: "features[0].match[0].maxLength")
    expectDecodeFailure(try Fixture.json { $0.removeValue(forKey: "features") }, field: "features")
    expectDecodeFailure(
      try Fixture.json { Fixture.editFeature(&$0, 0) { $0["keywords"] = ["jwt", 2] } }, field: "features[0].keywords[1]")
    expectDecodeFailure(
      try Fixture.json { Fixture.editRule(&$0, 0, 0) { $0["type"] = "glob" } }, field: "features[0].match[0].type")
    expectDecodeFailure(
      try Fixture.json { Fixture.editRule(&$0, 0, 0) { $0.removeValue(forKey: "pattern") } },
      field: "features[0].match[0].pattern")
    expectDecodeFailure(
      try Fixture.json { Fixture.editAction(&$0, 0) { $0.removeValue(forKey: "type") } }, field: "features[0].action.type")
    expectDecodeFailure(
      try Fixture.json { Fixture.editAction(&$0, 1) { $0["output"] = "html" } }, field: "features[1].action.output")
    expectDecodeFailure(
      try Fixture.json { Fixture.editAction(&$0, 1) { $0 = ["type": "builtin", "handler": "nope"] } },
      source: .builtin, field: "features[1].action.handler")
  }

  /// 文件级错误：太大、不是 UTF-8、不是 JSON、根不是对象，都指向清单文件本身。
  @Test func fileLevelErrorsPointAtManifestFile() throws {
    let tooLarge = Data(repeating: UInt8(ascii: " "), count: ToolManifest.maximumFileBytes + 1)
    expectDecodeFailure(tooLarge, field: ToolManifest.fileName)
    let utf16 = try #require(Fixture.documentExample.data(using: .utf16))
    expectDecodeFailure(utf16, field: ToolManifest.fileName)
    expectDecodeFailure(Data("{\"id\": ".utf8), field: ToolManifest.fileName)
    expectDecodeFailure(Data("[1, 2]".utf8), field: ToolManifest.fileName)
  }

  /// 解码通过后仍执行取值校验：`aster.` 前缀只给内置来源。
  @Test func decodeRunsValidation() throws {
    expectDecodeFailure(try Fixture.json { $0["id"] = "aster.jwt" }, field: "id")
    let builtin = try ToolManifest.decode(try Fixture.json { $0["id"] = "aster.jwt" }, source: .builtin)
    #expect(builtin.id == "aster.jwt")
  }

  /// 脚本超时：缺省 10 秒、list 缺省 3 秒，显式值收进 1–60。
  @Test func scriptTimeoutDefaults() {
    #expect(ToolScriptAction(command: ["a"], output: .list).resolvedTimeout == ScriptToolProtocol.listTimeout)
    #expect(ToolScriptAction(command: ["a"], output: .none).resolvedTimeout == ScriptToolProtocol.defaultTimeout)
    #expect(ToolScriptAction(command: ["a"], timeout: 30).resolvedTimeout == 30)
    #expect(ToolScriptAction(command: ["a"], timeout: 600).resolvedTimeout == ScriptToolProtocol.maximumTimeout)
  }
}
