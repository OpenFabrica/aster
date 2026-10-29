// 内置 Agent 速率条 aster.codexbar / aster.claudebar：清单按内置规则通过校验，脚本按 Pane 绑定的会话 ID
// 读假会话记录，输出模型、状态、速率与累计；不是对应 Agent 的 Pane 输出空列表。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 仓库根目录（本文件在 `Tests/AsterTests/Tools/` 下）。
private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private func pluginDirectory(_ id: String) -> URL {
  repositoryRoot().appendingPathComponent("Resources/tools-builtin/\(id)", isDirectory: true)
}

/// 本机能用的 python3（与入口脚本的查找顺序一致）；没有时脚本测试跳过。
private func pythonAvailable() -> Bool {
  ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3"]
    .contains { FileManager.default.isExecutableFile(atPath: $0) }
    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3")
}

/// 跑插件入口脚本，返回解析后的 JSON 对象。环境变量只给测试指定的几项，不继承用户的 CODEX_HOME 等。
private func runBar(_ id: String, script: String, stdin: [String: Any], environment: [String: String]) throws
  -> [String: Any]
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [pluginDirectory(id).appendingPathComponent(script).path]
  process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "ASTER_LOCALE": "zh-Hans"].merging(environment) { $1 }
  let stdout = Pipe()
  let input = Pipe()
  process.standardOutput = stdout
  process.standardError = FileHandle.nullDevice
  process.standardInput = input
  try process.run()
  input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: stdin))
  try input.fileHandleForWriting.close()
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 项目列表里按 id 取的 `text`。
private func texts(_ output: [String: Any]) -> [String: String] {
  let items = output["items"] as? [[String: Any]] ?? []
  return Dictionary(items.compactMap { item in (item["id"] as? String).map { ($0, item["text"] as? String ?? "") } }) {
    first, _ in first
  }
}

/// 所有假记录共用的基准时间：各行之间的间隔精确，速率断言不受执行耗时影响。
private let fixtureNow = Date()

/// 距基准时间 `offset` 秒的 ISO 时间串（会话记录的格式）。
private func iso(_ offset: TimeInterval) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: fixtureNow.addingTimeInterval(offset))
}

/// 把对象逐行写成 JSONL。
private func jsonl(_ objects: [[String: Any]]) throws -> Data {
  var data = Data()
  for object in objects {
    data.append(try JSONSerialization.data(withJSONObject: object))
    data.append(0x0A)
  }
  return data
}

private func temporaryDirectory(_ prefix: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test("两个速率条清单按内置规则通过校验：只有 pane.bottom 视图，按 agent 与 cwd 触发，脚本可执行")
func agentBarManifestsValidateAsBuiltin() throws {
  for (id, script) in [("aster.codexbar", "bin/codexbar.sh"), ("aster.claudebar", "bin/claudebar.sh")] {
    let directory = pluginDirectory(id)
    let manifest = try ToolManifest.decode(
      Data(contentsOf: directory.appendingPathComponent(ToolManifest.fileName)), source: .builtin)
    #expect(manifest.id == id && manifest.features.isEmpty)
    #expect(manifest.permissions.contains(.exec))
    let view = try #require(manifest.view(id: "rate"))
    #expect(view.kind == .bar && view.slot == .paneBottom)
    #expect(view.source?.command == [script])
    #expect(view.resolvedRefresh.resolvedTriggers == [.agent, .cwd])
    #expect(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(script).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("icon.svg").path))
  }
}

@Test("不是对应 Agent 的 Pane：入口脚本直接输出空列表，不需要 python")
func agentBarsHideOnOtherPanes() throws {
  for (id, script, other) in [
    ("aster.codexbar", "bin/codexbar.sh", "claudeCode"), ("aster.claudebar", "bin/claudebar.sh", "codex"),
  ] {
    let plain = try runBar(id, script: script, stdin: ["context": [:]], environment: [:])
    #expect((plain["items"] as? [Any])?.isEmpty == true && plain["ttl"] as? Int == 600)
    let wrong = try runBar(
      id, script: script, stdin: ["context": ["agent": ["provider": other, "state": "idle"]]],
      environment: ["ASTER_AGENT": other])
    #expect((wrong["items"] as? [Any])?.isEmpty == true)
  }
}

@Test("Codex 速率条：按绑定的会话 ID 找记录，输出模型、状态、最近区间速率与累计")
func codexBarReportsBoundSession() throws {
  guard pythonAvailable() else { return }
  let home = try temporaryDirectory("codexbar")
  defer { try? FileManager.default.removeItem(at: home) }
  let sessionID = "01a182d4-fd23-7070-9699-6d43bc6e6077"
  let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
  let day = home.appendingPathComponent(
    String(format: "sessions/%04d/%02d/%02d", today.year!, today.month!, today.day!), isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  // 两次累计用量相隔 10 秒，差值 20000 / 500 → 入 2.0k/s、出 50/s。
  let usage: (Int, Int, TimeInterval) -> [String: Any] = { input, output, offset in
    [
      "timestamp": iso(offset), "type": "event_msg",
      "payload": [
        "type": "token_count",
        "info": ["total_token_usage": ["input_tokens": input, "output_tokens": output]],
      ],
    ]
  }
  try jsonl([
    ["timestamp": iso(-60), "type": "session_meta", "payload": ["id": sessionID, "cwd": "/tmp/project"]],
    ["timestamp": iso(-50), "type": "turn_context", "payload": ["model": "gpt-test", "effort": "high"]],
    ["timestamp": iso(-40), "type": "event_msg", "payload": ["type": "task_started"]],
    usage(10000, 100, -30),
    usage(30000, 600, -20),
  ]).write(to: day.appendingPathComponent("rollout-2026-10-28T22-05-58-\(sessionID).jsonl"))

  let output = try runBar(
    "aster.codexbar", script: "bin/codexbar.sh",
    stdin: ["context": ["agent": ["provider": "codex", "state": "processing", "sessionID": sessionID]]],
    environment: ["ASTER_AGENT": "codex", "CODEX_HOME": home.path])
  let values = texts(output)
  #expect(values["model"] == "gpt-test · high")
  #expect(values["status"] == "进行中")
  #expect(values["rate"] == "入 2.0k/s · 出 50/s")
  #expect(values["total"] == "累计 30.0k / 600")
  #expect(output["ttl"] as? Int == 5)

  // 别的会话 ID 找不到记录、也没有 cwd 可回退：隐藏。
  let missing = try runBar(
    "aster.codexbar", script: "bin/codexbar.sh",
    stdin: ["context": ["agent": ["provider": "codex", "state": "idle", "sessionID": "nope"]]],
    environment: ["ASTER_AGENT": "codex", "CODEX_HOME": home.path])
  #expect((missing["items"] as? [Any])?.isEmpty == true)
}

@Test("Claude Code 速率条：同一条回复多行只算一次，增量统计累计输入 / 输出，没绑定 ID 时按目录回退")
func claudeBarReportsBoundSessionIncrementally() throws {
  guard pythonAvailable() else { return }
  let config = try temporaryDirectory("claudebar")
  let data = try temporaryDirectory("claudebar-data")
  defer {
    try? FileManager.default.removeItem(at: config)
    try? FileManager.default.removeItem(at: data)
  }
  let cwd = "/tmp/my.project"
  let sessionID = "070d0e48-4d95-456f-bb8d-19011cf85eb1"
  let projectDirectory = config.appendingPathComponent("projects/-tmp-my-project", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
  let file = projectDirectory.appendingPathComponent("\(sessionID).jsonl")
  // 回复的一行：键顺序与真实记录一致（uuid 紧跟 timestamp），用量带缓存读写。
  let reply: (String, Int, TimeInterval) -> [String: Any] = { id, output, offset in
    [
      "isSidechain": false, "type": "assistant", "uuid": UUID().uuidString, "timestamp": iso(offset),
      "effort": "high",
      "message": [
        "id": id, "model": "claude-test-1",
        "usage": [
          "input_tokens": 2, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 9000,
          "output_tokens": output,
        ],
      ],
    ]
  }
  let prompt: (TimeInterval) -> [String: Any] = { offset in
    ["type": "user", "uuid": UUID().uuidString, "timestamp": iso(offset)]
  }
  // 第一条回复 m1 写了两行（思考 + 文字），以最后一行的 300 为准；用时 30s − 20s = 10s → 出 30/s；新输入 2 + 1000 = 1002 → 入 100/s。
  try jsonl([prompt(-30), reply("m1", 120, -25), reply("m1", 300, -20)]).write(to: file)
  let environment = [
    "ASTER_AGENT": "claudeCode", "CLAUDE_CONFIG_DIR": config.path, "ASTER_PLUGIN_DATA": data.path,
  ]
  let bound: [String: Any] = [
    "context": ["agent": ["provider": "claudeCode", "state": "idle", "sessionID": sessionID], "workingDirectory": cwd]
  ]
  let first = texts(try runBar("aster.claudebar", script: "bin/claudebar.sh", stdin: bound, environment: environment))
  #expect(first["model"] == "test-1 · high")
  #expect(first["status"] == "待输入")
  #expect(first["rate"] == "入 100/s · 出 30/s")
  #expect(first["context"] == "上下文 10.0k")
  #expect(first["total"] == "累计 1.0k / 300")
  #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("sessions/\(sessionID).json").path))

  // 追加第二条回复与一行子代理往来：累计输出 300 + 200、新输入 1002 × 2，子代理不算。
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  var sidechain = reply("s1", 9999, -5)
  sidechain["isSidechain"] = true
  try handle.write(contentsOf: jsonl([prompt(-10), reply("m2", 200, -6), sidechain]))
  try handle.close()
  let second = texts(try runBar("aster.claudebar", script: "bin/claudebar.sh", stdin: bound, environment: environment))
  #expect(second["total"] == "累计 2.0k / 500")
  #expect(second["rate"] == "入 250/s · 出 50/s")

  // 没绑定会话 ID：按编码后的目录名找最近写入的会话。
  let unbound: [String: Any] = [
    "context": ["agent": ["provider": "claudeCode", "state": "processing"], "workingDirectory": cwd]
  ]
  let fallback = try runBar("aster.claudebar", script: "bin/claudebar.sh", stdin: unbound, environment: environment)
  #expect(texts(fallback)["status"] == "进行中" && texts(fallback)["total"] == "累计 2.0k / 500")
  #expect(fallback["ttl"] as? Int == 5)
}
