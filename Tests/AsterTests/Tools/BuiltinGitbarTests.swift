// 内置示例插件 aster.gitbar：清单按内置规则通过校验，bin/gitbar.sh 在真实 git 仓库里输出正确的项目列表。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 仓库根目录（本文件在 `Tests/AsterTests/Tools/` 下）。
private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private let gitbarDirectory = repositoryRoot().appendingPathComponent("Resources/tools-builtin/aster.gitbar", isDirectory: true)

/// 本机 git 的路径；没有时测试跳过。
private func gitExecutable() -> String? {
  ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// 运行一个进程并返回标准输出；失败（非零退出）时抛错。
@discardableResult
private func run(_ executable: String, _ arguments: [String], in directory: URL, environment: [String: String] = [:], input: String? = nil) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.currentDirectoryURL = directory
  var env = ProcessInfo.processInfo.environment
  env.merge(environment) { $1 }
  process.environment = env
  let stdout = Pipe()
  let stdin = Pipe()
  process.standardOutput = stdout
  process.standardError = FileHandle.nullDevice
  process.standardInput = stdin
  try process.run()
  if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
  try stdin.fileHandleForWriting.close()
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
  return String(decoding: data, as: UTF8.self)
}

/// 在临时目录里用 git 命令；固定作者信息，不读用户全局配置。
private func git(_ arguments: [String], in directory: URL) throws {
  try run(
    gitExecutable()!, ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments,
    in: directory)
}

/// 跑 gitbar.sh，返回解析后的 JSON 对象。
private func runGitbar(cwd: URL, input: String = #"{"context":{"isRemote":false}}"#, locale: String = "zh-Hans") throws -> [String: Any] {
  let script = gitbarDirectory.appendingPathComponent("bin/gitbar.sh").path
  let output = try run(
    "/bin/sh", [script], in: cwd, environment: ["ASTER_CWD": cwd.path, "ASTER_LOCALE": locale], input: input)
  return try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

/// 项目列表里每项的 `text`（没有文字的项目记为空串）。
private func texts(_ output: [String: Any]) throws -> [String] {
  let items = try #require(output["items"] as? [[String: Any]])
  return items.map { $0["text"] as? String ?? "" }
}

/// 建一个带初始提交的临时仓库，分支叫 `branch`。
private func makeRepository(branch: String = "main") throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitbar-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try git(["init", "-q", "-b", branch], in: root)
  try git(["commit", "-q", "--allow-empty", "-m", "init"], in: root)
  return root
}

@Test("gitbar 清单按内置规则通过校验：只有视图没有功能，脚本视图声明了 exec")
func gitbarManifestValidatesAsBuiltin() throws {
  let data = try Data(contentsOf: gitbarDirectory.appendingPathComponent(ToolManifest.fileName))
  let manifest = try ToolManifest.decode(data, source: .builtin)
  #expect(manifest.id == "aster.gitbar")
  #expect(manifest.features.isEmpty)
  #expect(manifest.permissions.contains(.exec))
  let view = try #require(manifest.view(id: "branch"))
  #expect(view.kind == .bar && view.slot == .tabBottom)
  #expect(view.source?.command == ["bin/gitbar.sh"])
  #expect(view.resolvedRefresh.resolvedInterval == 30)
  #expect(view.resolvedRefresh.resolvedTriggers == [.cwd, .branch, .activePane])
  // 脚本与图标真实存在，脚本可执行。
  #expect(FileManager.default.isExecutableFile(atPath: gitbarDirectory.appendingPathComponent("bin/gitbar.sh").path))
  #expect(FileManager.default.fileExists(atPath: gitbarDirectory.appendingPathComponent("icon.svg").path))
}

@Test("gitbar 脚本：输出分支、未跟踪与已修改文件数、ahead / behind，分支名里的引号被转义")
func gitbarScriptReportsBranchAndDirtyCount() throws {
  guard gitExecutable() != nil else { return }
  let root = try makeRepository(branch: "feature/a\"b")
  defer { try? FileManager.default.removeItem(at: root) }

  // 干净仓库：分支 + 刷新按钮，没有脏标记。
  let clean = try runGitbar(cwd: root)
  #expect(try texts(clean) == ["feature/a\"b", ""])
  let first = try #require((clean["items"] as? [[String: Any]])?.first)
  #expect(first["icon"] as? String == "arrow.triangle.branch")
  let copy = try #require(first["onClick"] as? [String: Any])
  #expect(copy["type"] as? String == "copy" && copy["text"] as? String == "feature/a\"b")

  // 一个未跟踪文件加一个已跟踪后修改的文件 = 2。
  try "a".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
  try git(["add", "tracked.txt"], in: root)
  try git(["commit", "-q", "-m", "add"], in: root)
  try "b".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
  try "c".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
  let dirty = try runGitbar(cwd: root)
  #expect(try texts(dirty) == ["feature/a\"b", "●2", ""])
  let dirtyItem = try #require((dirty["items"] as? [[String: Any]])?[1])
  #expect(dirtyItem["color"] as? String == "warning")
  #expect(dirtyItem["tooltip"] as? String == "2 个文件有改动")
  #expect(try runGitbar(cwd: root, locale: "en")["items"].flatMap { ($0 as? [[String: Any]])?[1]["tooltip"] as? String } == "2 files changed")

  // 有上游：本地多一个提交 → ↑1，点击预填 git push（只插入）。
  let remote = FileManager.default.temporaryDirectory.appendingPathComponent("gitbar-remote-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: remote) }
  try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
  try git(["init", "-q", "--bare"], in: remote)
  try git(["remote", "add", "origin", remote.path], in: root)
  try git(["push", "-q", "-u", "origin", "HEAD"], in: root)
  try git(["commit", "-q", "--allow-empty", "-m", "ahead"], in: root)
  let ahead = try runGitbar(cwd: root)
  #expect(try texts(ahead) == ["feature/a\"b", "↑1", "●2", ""])
  let push = try #require(((ahead["items"] as? [[String: Any]])?[1])?["onClick"] as? [String: Any])
  #expect(push["type"] as? String == "terminal" && push["text"] as? String == "git push" && push["mode"] as? String == "insert")
}

@Test("gitbar 脚本：非仓库、无 cwd 或远端标签输出空项目")
func gitbarScriptHidesOutsideLocalRepositories() throws {
  guard gitExecutable() != nil else { return }
  let plain = FileManager.default.temporaryDirectory.appendingPathComponent("gitbar-plain-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: plain) }
  // 非仓库目录。
  #expect(try texts(runGitbar(cwd: plain)).isEmpty)

  // 远端标签：即使 cwd 恰好是本地仓库也隐藏。
  let root = try makeRepository()
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(try texts(runGitbar(cwd: root, input: #"{"context":{"isRemote":true}}"#)).isEmpty)

  // 没有 ASTER_CWD。
  let script = gitbarDirectory.appendingPathComponent("bin/gitbar.sh").path
  var environment = ProcessInfo.processInfo.environment
  environment["ASTER_CWD"] = nil
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [script]
  process.environment = environment
  let stdout = Pipe()
  process.standardOutput = stdout
  process.standardInput = FileHandle.nullDevice
  try process.run()
  let data = stdout.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect((object["items"] as? [Any])?.isEmpty == true)
  #expect(object["ttl"] as? Int == 600)
}
