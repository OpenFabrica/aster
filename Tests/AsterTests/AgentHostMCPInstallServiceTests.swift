// AgentHostMCPInstallService 的命令路径选择：MCP 配置只能写 PATH 里的稳定 `aster` 路径，
// 不能写 App 包内的绝对路径（开发构建删除或换装正式版后会失效，Claude Code 启动即报错）。
import Foundation
import Testing

@testable import Aster

/// 在临时目录里准备一个假的 aster-cli 与安装目录。
private func makeSandbox() throws -> (root: URL, binDirectory: String, executable: URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("aster-mcp-path-\(UUID().uuidString)")
  let bundleMacOS = root.appendingPathComponent("Aster.app/Contents/MacOS")
  try FileManager.default.createDirectory(at: bundleMacOS, withIntermediateDirectories: true)
  let executable = bundleMacOS.appendingPathComponent("aster-cli")
  try Data("#!/bin/sh\n".utf8).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  let bin = root.appendingPathComponent("bin").path
  try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
  return (root, bin, executable)
}

@Test func stableCommandPathIsNilWhenAsterCommandMissing() throws {
  let sandbox = try makeSandbox()
  defer { try? FileManager.default.removeItem(at: sandbox.root) }
  #expect(AgentHostMCPInstallService.stableCommandPath(directories: [sandbox.binDirectory]) == nil)
}

@Test func ensureStableCommandPathInstallsSymlinkAndReturnsItsPath() throws {
  let sandbox = try makeSandbox()
  defer { try? FileManager.default.removeItem(at: sandbox.root) }
  let result = AgentHostMCPInstallService.ensureStableCommandPath(
    directories: [sandbox.binDirectory], executableURL: sandbox.executable)
  let path = try result.get()
  #expect(path == (sandbox.binDirectory as NSString).appendingPathComponent("aster"))
  #expect(!path.contains(".app/"), "MCP 配置不能写 App 包内路径")
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == sandbox.executable.path)
}

@Test func stableCommandPathKeepsSymlinkThatPointsToAnotherAster() throws {
  let sandbox = try makeSandbox()
  defer { try? FileManager.default.removeItem(at: sandbox.root) }
  // 例如 /usr/local/bin/aster 指向 /Applications 里的正式版：仍写稳定路径，不改指向。
  let link = (sandbox.binDirectory as NSString).appendingPathComponent("aster")
  try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/Applications/Aster.app/Contents/MacOS/aster-cli")
  #expect(AgentHostMCPInstallService.stableCommandPath(directories: [sandbox.binDirectory]) == link)
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/Applications/Aster.app/Contents/MacOS/aster-cli")
}
