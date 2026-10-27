// 清单顶层字段校验：版本、id 与保留前缀、文本字段、主页、路径、界面、权限与域名。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolManifestValidation")
struct ToolManifestValidationTests {
  typealias Fixture = ToolManifestFixture

  /// 夹具清单对用户来源与开发来源都合法。
  @Test func fixtureIsValid() throws {
    try Fixture.manifest().validate(source: .user)
    try Fixture.manifest().validate(source: .development)
  }

  /// schemaVersion 只接受 1。
  @Test func schemaVersionMustBeOne() {
    var manifest = Fixture.manifest()
    manifest.schemaVersion = 2
    expectInvalid(manifest, field: "schemaVersion")
  }

  /// id 必须是小写点分格式、≤ 128 字节；`aster.` 前缀只给内置来源。
  @Test func idFormatLengthAndReservedPrefix() throws {
    var manifest = Fixture.manifest()
    for valid in ["a.b", "com.example-1.x9", "0.0", "a1.b-c.d"] {
      manifest.id = valid
      try manifest.validate(source: .user)
    }
    for invalid in ["com", "Com.example", "com..x", ".com.x", "com.x.", "com.-x", "com.x_y", "com/x", "com.例子", "a-b.c"] {
      manifest.id = invalid
      expectInvalid(manifest, field: "id")
    }
    manifest.id = "a." + String(repeating: "b", count: 126)
    try manifest.validate(source: .user)
    manifest.id += "c"
    expectInvalid(manifest, field: "id")
    manifest.id = "aster.tool"
    expectInvalid(manifest, source: .user, field: "id")
    expectInvalid(manifest, source: .development, field: "id")
  }

  /// name 必填、≤ 64 个字符、不含控制字符或双向文本控制符。
  @Test func nameRules() throws {
    var manifest = Fixture.manifest()
    manifest.name = String(repeating: "名", count: 64)
    try manifest.validate(source: .user)
    for invalid in ["", "   ", String(repeating: "名", count: 65), "a\nb", "a\u{7}b", "abc\u{202E}gpj.exe", "a\u{2028}b"] {
      manifest.name = invalid
      expectInvalid(manifest, field: "name")
    }
  }

  /// version 符合 `x.y.z[-+后缀]`（只认 ASCII 数字）且 ≤ 32 个字符。
  @Test func versionRules() throws {
    var manifest = Fixture.manifest()
    for valid in ["0.0.0", "10.20.30", "1.2.3-beta.1", "1.2.3+build-5"] {
      manifest.version = valid
      try manifest.validate(source: .user)
    }
    for invalid in ["1.2", "1.2.3.4", "v1.2.3", "1.2.3-", "1.2.3-beta+1", "１.２.３", "1..3", "", "1.2.3-" + String(repeating: "a", count: 30)] {
      manifest.version = invalid
      expectInvalid(manifest, field: "version")
    }
  }

  /// description ≤ 512、author ≤ 128，都不能含控制字符。
  @Test func optionalTextLimits() throws {
    var manifest = Fixture.manifest()
    manifest.description = String(repeating: "d", count: 512)
    manifest.author = String(repeating: "a", count: 128)
    try manifest.validate(source: .user)
    manifest.description = String(repeating: "d", count: 513)
    expectInvalid(manifest, field: "description")
    manifest.description = "line\nbreak"
    expectInvalid(manifest, field: "description")
    manifest.description = nil
    manifest.author = String(repeating: "a", count: 129)
    expectInvalid(manifest, field: "author")
  }

  /// homepage 必须是带主机的 https:// 地址，≤ 512。
  @Test func homepageMustBeHTTPS() throws {
    var manifest = Fixture.manifest()
    manifest.homepage = "https://example.com/a?b=c"
    try manifest.validate(source: .user)
    for invalid in ["http://example.com", "ftp://example.com", "https://", "example.com", "https:// example.com",
      "https://example.com/" + String(repeating: "a", count: 500)]
    {
      manifest.homepage = invalid
      expectInvalid(manifest, field: "homepage")
    }
  }

  /// 图标与入口路径：相对、无 `..`、无控制字符、≤ 256；图标扩展名白名单（大小写无关），入口以 .html 结尾。
  @Test func pathRules() throws {
    var manifest = Fixture.manifest()
    manifest.icon = "icons/Logo.PNG"
    manifest.ui = ToolUIConfig(main: "web/Index.HTML")
    try manifest.validate(source: .user)
    for invalid in ["/abs.svg", "../x.svg", "a/../x.svg", "icon.gif", "", "a\u{0}.svg", String(repeating: "a", count: 253) + ".svg"] {
      manifest.icon = invalid
      expectInvalid(manifest, field: "icon")
    }
    manifest.icon = nil
    for invalid in ["index.htm", "/index.html", "../index.html", "index.html.js"] {
      manifest.ui = ToolUIConfig(main: invalid)
      expectInvalid(manifest, field: "ui.main")
    }
  }

  /// ui.height 在 120–800。
  @Test func uiHeightRange() throws {
    var manifest = Fixture.manifest()
    for valid in [120, 800] {
      manifest.ui = ToolUIConfig(main: "index.html", height: valid)
      try manifest.validate(source: .user)
    }
    for invalid in [119, 801, 0] {
      manifest.ui = ToolUIConfig(main: "index.html", height: invalid)
      expectInvalid(manifest, field: "ui.height")
    }
  }

  /// 权限不能重复，错误指向重复的那一项。
  @Test func permissionsMustBeUnique() {
    var manifest = Fixture.manifest()
    manifest.permissions = [.exec, .notify, .exec]
    expectInvalid(manifest, field: "permissions[2]")
  }

  /// network 只在声明 network 权限时必填（1–16 项），每项是小写主机名或 `*.主机名`。
  @Test func networkDomains() throws {
    var manifest = Fixture.manifest()
    manifest.network = ["example.com"]
    expectInvalid(manifest, field: "network")
    manifest.permissions.append(.network)
    manifest.network = []
    expectInvalid(manifest, field: "network")
    manifest.network = ["*.example.com", "api.example.com", "localhost", "xn--bcher-kva.de"]
    try manifest.validate(source: .user)
    manifest.network = (0..<17).map { "h\($0).example.com" }
    expectInvalid(manifest, field: "network")
    for invalid in ["https://a.com", "a.com:443", "a.com/x", "A.com", "*.", "*", "-a.com", "a-.com", "a..com", "*.*.a.com", "a.com."] {
      manifest.network = ["ok.example.com", invalid]
      expectInvalid(manifest, field: "network[1]")
    }
  }
}
