// 内置系统状态条 aster.sysbar：清单按内置规则通过校验，脚本只用系统命令输出 CPU、内存、磁盘，
// 有上次采样时再输出网速；文案跟着 ASTER_LOCALE。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 插件目录（本文件在 `Tests/AsterTests/Tools/` 下）。
private let sysbarDirectory = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Resources/tools-builtin/aster.sysbar", isDirectory: true)

/// 跑入口脚本，返回解析后的 JSON 对象。环境变量只给固定 PATH 与测试指定的几项。
private func runSysbar(_ environment: [String: String]) throws -> [String: Any] {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [sysbarDirectory.appendingPathComponent("bin/sysbar.sh").path]
  process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
  let stdout = Pipe()
  let input = Pipe()
  process.standardOutput = stdout
  process.standardError = FileHandle.nullDevice
  process.standardInput = input
  try process.run()
  input.fileHandleForWriting.write(Data(#"{"context":{}}"#.utf8))
  try input.fileHandleForWriting.close()
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 项目列表里按 id 取的 `text`。
private func sysbarTexts(_ output: [String: Any]) -> [String: String] {
  let items = output["items"] as? [[String: Any]] ?? []
  return Dictionary(items.compactMap { item in (item["id"] as? String).map { ($0, item["text"] as? String ?? "") } }) {
    first, _ in first
  }
}

/// 整串匹配正则。
private func matches(_ text: String?, _ pattern: String) -> Bool {
  guard let text else { return false }
  return text.range(of: "^\(pattern)$", options: .regularExpression) != nil
}

@Test("系统状态条清单按内置规则通过校验：window.bottom，只按 10 秒间隔刷新，只要 exec")
func sysbarManifestValidatesAsBuiltin() throws {
  let manifest = try ToolManifest.decode(
    Data(contentsOf: sysbarDirectory.appendingPathComponent(ToolManifest.fileName)), source: .builtin)
  #expect(manifest.id == "aster.sysbar" && manifest.features.isEmpty)
  #expect(manifest.permissions == [.exec])
  let view = try #require(manifest.view(id: "stats"))
  #expect(view.kind == .bar && view.slot == .windowBottom)
  #expect(view.source?.command == ["bin/sysbar.sh"])
  #expect(view.resolvedRefresh.resolvedTriggers.isEmpty)
  #expect(view.resolvedRefresh.interval == 10)
  #expect(FileManager.default.isExecutableFile(atPath: sysbarDirectory.appendingPathComponent("bin/sysbar.sh").path))
}

@Test("系统状态条：首次只有 CPU / 内存 / 磁盘并 5 秒后重跑；有上次采样后出网速；英文界面换文案")
func sysbarReportsStatsAndNetworkRate() throws {
  let data = FileManager.default.temporaryDirectory.appendingPathComponent("sysbar-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: data) }
  let environment = ["ASTER_LOCALE": "zh-Hans", "ASTER_PLUGIN_DATA": data.path]

  let first = try runSysbar(environment)
  let values = sysbarTexts(first)
  #expect(matches(values["cpu"], #"CPU \d{1,3}%"#))
  #expect(matches(values["memory"], #"内存 \d+\.\d/\d+G"#))
  #expect(matches(values["disk"], #"磁盘 余 [\d.]+[kMGT]?B?"#))
  #expect(values["network"] == nil)
  #expect(first["ttl"] as? Int == 5)

  // 把基准改成 10 秒前、计数为 0：这次按 10 秒间隔算出网速，并按清单间隔刷新。
  let state = data.appendingPathComponent("network.state")
  let now = Int(Date().timeIntervalSince1970)
  try "\(now - 10) 0 0 - - 0\n".write(to: state, atomically: true, encoding: .utf8)
  let second = try runSysbar(environment)
  #expect(matches(sysbarTexts(second)["network"], #"↓[\d.]+[kMGT]?B?/s ↑[\d.]+[kMGT]?B?/s"#))
  #expect(second["ttl"] == nil)

  // 两秒内再跑（别的窗口刚跑过）：沿用上次的速率，不改基准。
  let saved = try String(contentsOf: state, encoding: .utf8)
  let english = sysbarTexts(try runSysbar(["ASTER_LOCALE": "en", "ASTER_PLUGIN_DATA": data.path]))
  #expect(matches(english["memory"], #"mem \d+\.\d/\d+G"#))
  #expect(english["disk"]?.hasSuffix(" free") == true)
  #expect(english["network"] == sysbarTexts(second)["network"])
  #expect(try String(contentsOf: state, encoding: .utf8) == saved)
}

@Test("没有插件数据目录：不显示网速，也不加快刷新")
func sysbarWithoutDataDirectorySkipsNetwork() throws {
  let output = try runSysbar(["ASTER_LOCALE": "zh-Hans"])
  #expect(sysbarTexts(output)["network"] == nil && sysbarTexts(output)["cpu"] != nil)
  #expect(output["ttl"] == nil)
}
