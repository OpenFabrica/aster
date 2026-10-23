import Foundation
import Testing

@testable import AsterCore

/// 正式版 / 开发版的身份判定与数据目录划分。
struct AsterAppIdentityTests {
  @Test("按 bundle ID 判定身份：开发版 ID 与不在 App 包里都算开发版")
  func identityFromBundleIdentifier() {
    #expect(AsterAppIdentity(appBundleIdentifier: AsterAppIdentity.releaseBundleIdentifier) == .release)
    #expect(AsterAppIdentity(appBundleIdentifier: AsterAppIdentity.developmentBundleIdentifier) == .development)
    #expect(AsterAppIdentity(appBundleIdentifier: nil) == .development)
    #expect(AsterAppIdentity(appBundleIdentifier: "com.example.fork") == .release)
  }

  @Test("两个身份的数据目录与钥匙串后缀互不相同")
  func dataLocationsDiffer() {
    #expect(AsterAppIdentity.release.dataDirectoryName == "Aster")
    #expect(AsterAppIdentity.development.dataDirectoryName == "Aster-Dev")
    #expect(AsterAppIdentity.release.keychainServiceSuffix.isEmpty)
    #expect(AsterAppIdentity.development.keychainServiceSuffix == ".dev")
    let release = AsterAppIdentity.release.applicationSupportDirectory()
    let development = AsterAppIdentity.development.applicationSupportDirectory()
    #expect(release.lastPathComponent == "Aster")
    #expect(development.lastPathComponent == "Aster-Dev")
    #expect(release.deletingLastPathComponent() == development.deletingLastPathComponent())
  }

  @Test("持久化文件的默认路径跟着身份走")
  func storesFollowIdentity() {
    #expect(SSHHostStore.defaultFileURL(identity: .release).path.hasSuffix("/Aster/hosts.json"))
    #expect(SSHHostStore.defaultFileURL(identity: .development).path.hasSuffix("/Aster-Dev/hosts.json"))
    #expect(MachineProfileStore.defaultFileURL(identity: .release).path.hasSuffix("/Aster/machines.json"))
    #expect(MachineProfileStore.defaultFileURL(identity: .development).path.hasSuffix("/Aster-Dev/machines.json"))
  }

  @Test("经符号链接启动包内可执行文件时，仍按包的 bundle ID 认身份")
  func enclosingBundleResolvesSymlinks() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("AsterAppIdentityTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let app = root.appendingPathComponent("Aster.app", isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": AsterAppIdentity.developmentBundleIdentifier,
      "CFBundlePackageType": "APPL",
      "CFBundleExecutable": "Aster",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let executable = macOS.appendingPathComponent("aster-cli")
    try Data().write(to: executable)
    // 模拟设置页装的 /usr/local/bin/aster：一个指向包内 aster-cli 的符号链接。
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
    let link = bin.appendingPathComponent("aster")
    try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)

    #expect(AsterAppIdentity.enclosingAppBundleIdentifier(executableURL: executable)
      == AsterAppIdentity.developmentBundleIdentifier)
    #expect(AsterAppIdentity.enclosingAppBundleIdentifier(executableURL: link)
      == AsterAppIdentity.developmentBundleIdentifier)
    // 不在 X.app/Contents/MacOS/ 布局里（SwiftPM 构建产物）时没有 bundle ID。
    #expect(AsterAppIdentity.enclosingAppBundleIdentifier(
      executableURL: root.appendingPathComponent("debug/aster-cli")) == nil)
  }

  @Test("测试宿主不在 App 包里，按开发版处理，默认路径碰不到正式版数据")
  func testHostIsDevelopment() {
    #expect(AsterAppIdentity.current == .development)
  }
}
