// 脚本工具可执行文件的解析：相对路径限定在插件目录内（含符号链接）、绝对路径原样使用、必须是可执行的普通文件。
import Foundation
import Testing

@testable import AsterCore

@Suite("ScriptToolProtocolExecutable")
struct ScriptToolProtocolExecutableTests {
  /// 一次测试用的临时目录：`plugin` 是插件目录，`outside` 是插件之外的目录；结束时整体删除。
  private struct Sandbox {
    let root: URL
    let plugin: URL
    let outside: URL

    /// 在带 UUID 的新目录下建好 plugin 与 outside。
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("aster-script-\(UUID().uuidString)", isDirectory: true)
      plugin = root.appendingPathComponent("plugin", isDirectory: true)
      outside = root.appendingPathComponent("outside", isDirectory: true)
      try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    /// 删除整个临时目录。
    func remove() {
      try? FileManager.default.removeItem(at: root)
    }

    /// 写一个 `#!/bin/sh` 脚本，`executable` 决定有没有 x 权限；返回文件地址。
    @discardableResult
    func script(_ path: String, in directory: URL, executable: Bool = true) throws -> URL {
      let url = directory.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
      return url
    }

    /// 在 `path` 处建一个指向 `destination` 的符号链接。
    func link(_ path: URL, to destination: URL) throws {
      try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: destination.path)
    }
  }

  /// 解析符号链接后的绝对路径（`/var` 实际是 `/private/var`，比较前双方都要解析）。
  private func realPath(_ url: URL) throws -> String {
    let resolved = try #require(realpath(url.path, nil))
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// 断言解析被拒绝，并且是 `invalidCommand`（不比较提示文案）。
  private func expectRejected(
    _ command: [String], in directory: URL, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let error = #expect(throws: ScriptToolError.self, sourceLocation: sourceLocation) {
      try ScriptToolProtocol.resolveExecutable(command, pluginDirectory: directory)
    }
    var isInvalidCommand = false
    if case .invalidCommand? = error { isInvalidCommand = true }
    #expect(isInvalidCommand, sourceLocation: sourceLocation)
  }

  // MARK: 相对路径

  /// 相对路径相对插件目录解析，返回解析后的真实路径与剩余参数；子目录和 `./` 前缀都行。
  @Test func relativeCommandResolvesInsidePluginDirectory() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.script("run.sh", in: sandbox.plugin)
    try sandbox.script("bin/tool", in: sandbox.plugin)
    let root = try realPath(sandbox.plugin)

    let plain = try ScriptToolProtocol.resolveExecutable(["run.sh", "-a", "b c"], pluginDirectory: sandbox.plugin)
    #expect(plain.executable.path == root + "/run.sh")
    #expect(plain.arguments == ["-a", "b c"])
    let nested = try ScriptToolProtocol.resolveExecutable(["bin/tool"], pluginDirectory: sandbox.plugin)
    #expect(nested.executable.path == root + "/bin/tool" && nested.arguments.isEmpty)
    let dotted = try ScriptToolProtocol.resolveExecutable(["./run.sh"], pluginDirectory: sandbox.plugin)
    #expect(dotted.executable.path == root + "/run.sh")
  }

  /// 字面上含 `..` 的路径一律拒绝（即使最终仍在插件目录里）；名字里只是带两个点的文件不算。
  @Test func parentDirectoryComponentIsRejectedButDottedNamesAreNot() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.script("run.sh", in: sandbox.plugin)
    try sandbox.script("bin/tool", in: sandbox.plugin)
    try sandbox.script("outside.sh", in: sandbox.root)
    try sandbox.script("..hidden.sh", in: sandbox.plugin)
    try sandbox.script("v1..2/tool", in: sandbox.plugin)

    for command in ["..", "../outside.sh", "bin/../run.sh", "bin/../../outside.sh", "a/../../outside.sh"] {
      expectRejected([command], in: sandbox.plugin)
    }
    let root = try realPath(sandbox.plugin)
    let hidden = try ScriptToolProtocol.resolveExecutable(["..hidden.sh"], pluginDirectory: sandbox.plugin)
    #expect(hidden.executable.path == root + "/..hidden.sh")
    let versioned = try ScriptToolProtocol.resolveExecutable(["v1..2/tool"], pluginDirectory: sandbox.plugin)
    #expect(versioned.executable.path == root + "/v1..2/tool")
  }

  /// 插件内的符号链接指向插件外的可执行文件（文件或目录）时拒绝；指向插件内时允许，并返回链接目标。
  @Test func symbolicLinksMustStayInsidePluginDirectory() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let outsideScript = try sandbox.script("evil.sh", in: sandbox.outside)
    try sandbox.script("real/run.sh", in: sandbox.plugin)
    try sandbox.link(sandbox.plugin.appendingPathComponent("escape"), to: outsideScript)
    try sandbox.link(sandbox.plugin.appendingPathComponent("escape-dir"), to: sandbox.outside)
    try sandbox.link(sandbox.plugin.appendingPathComponent("inside"), to: sandbox.plugin.appendingPathComponent("real/run.sh"))

    expectRejected(["escape"], in: sandbox.plugin)
    expectRejected(["escape-dir/evil.sh"], in: sandbox.plugin)
    let root = try realPath(sandbox.plugin)
    let resolved = try ScriptToolProtocol.resolveExecutable(["inside", "x"], pluginDirectory: sandbox.plugin)
    #expect(resolved.executable.path == root + "/real/run.sh")
    #expect(resolved.arguments == ["x"])
  }

  /// 同名前缀的兄弟目录不算插件内：`plugin-evil` 以 `plugin` 开头，但不在 `plugin/` 之下。
  @Test func siblingDirectoryWithSharedPrefixIsOutside() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let sibling = sandbox.root.appendingPathComponent("plugin-evil", isDirectory: true)
    let target = try sandbox.script("run.sh", in: sibling)
    try sandbox.link(sandbox.plugin.appendingPathComponent("sneaky"), to: target)
    expectRejected(["sneaky"], in: sandbox.plugin)
  }

  /// 插件目录本身可以是符号链接（登记的开发目录）：按它指向的真实目录解析。
  @Test func pluginDirectoryMayBeASymbolicLink() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.script("run.sh", in: sandbox.plugin)
    let linked = sandbox.root.appendingPathComponent("plugin-link")
    try sandbox.link(linked, to: sandbox.plugin)
    let root = try realPath(sandbox.plugin)
    let resolved = try ScriptToolProtocol.resolveExecutable(["run.sh"], pluginDirectory: linked)
    #expect(resolved.executable.path == root + "/run.sh")
  }

  /// 目录、没有 x 权限的文件、不存在的文件、插件目录本身（`.`）与不存在的插件目录都拒绝。
  @Test func nonExecutableTargetsAreRejected() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.script("plain.sh", in: sandbox.plugin, executable: false)
    try FileManager.default.createDirectory(at: sandbox.plugin.appendingPathComponent("bin"), withIntermediateDirectories: true)

    for command in ["bin", "plain.sh", "missing.sh", ".", "./", "bin/missing"] {
      expectRejected([command], in: sandbox.plugin)
    }
    let missingPlugin = sandbox.root.appendingPathComponent("no-such-plugin")
    expectRejected(["run.sh"], in: missingPlugin)
  }

  // MARK: 绝对路径与空命令

  /// 绝对路径原样使用（可以在插件目录之外），但同样必须是可执行的普通文件；参数照常返回。
  @Test func absoluteCommandIsUsedAsIs() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let outsideScript = try sandbox.script("tool.sh", in: sandbox.outside)
    let plain = try sandbox.script("plain.sh", in: sandbox.outside, executable: false)

    let system = try ScriptToolProtocol.resolveExecutable(["/bin/sh", "-c", "echo hi"], pluginDirectory: sandbox.plugin)
    #expect(system.executable == URL(fileURLWithPath: "/bin/sh"))
    #expect(system.arguments == ["-c", "echo hi"])
    let custom = try ScriptToolProtocol.resolveExecutable([outsideScript.path], pluginDirectory: sandbox.plugin)
    #expect(custom.executable.path == outsideScript.path)
    for command in ["/usr/bin", plain.path, sandbox.outside.appendingPathComponent("missing").path] {
      expectRejected([command], in: sandbox.plugin)
    }
  }

  /// 没有命令或命令是空串时拒绝。
  @Test func emptyCommandIsRejected() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    expectRejected([], in: sandbox.plugin)
    expectRejected([""], in: sandbox.plugin)
    expectRejected(["", "arg"], in: sandbox.plugin)
  }
}
