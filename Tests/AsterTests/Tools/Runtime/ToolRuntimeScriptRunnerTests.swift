// 脚本运行器：stdin 回显、超时结束、输出上限、非 0 退出带 stderr、取消、环境隔离与插件命令解析。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 运行固定程序的参数；环境只给 PATH，便于断言不继承 Aster 进程环境。
private func invocation(
  _ executable: String,
  _ arguments: [String] = [],
  stdin: String = "",
  timeout: TimeInterval = 5,
  environment: [String: String] = ["PATH": "/usr/bin:/bin"]
) -> ScriptToolInvocation {
  ScriptToolInvocation(
    executable: URL(fileURLWithPath: executable), arguments: arguments,
    workingDirectory: FileManager.default.temporaryDirectory.path, environment: environment,
    stdin: Data(stdin.utf8), timeout: timeout, terminationGrace: 0.3)
}

@Suite struct ToolRuntimeScriptRunnerTests {
  @Test func catEchoesStdinAndClosesIt() async throws {
    let output = try await ScriptToolRunner.run(invocation("/bin/cat", stdin: "hello\n世界"))
    #expect(String(decoding: output.stdout, as: UTF8.self) == "hello\n世界")
  }

  @Test func sleepIsTerminatedAtTimeout() async {
    let started = ContinuousClock.now
    await #expect(throws: ScriptToolError.timedOut) {
      _ = try await ScriptToolRunner.run(invocation("/bin/sleep", ["30"], timeout: 0.3))
    }
    #expect(ContinuousClock.now - started < .seconds(3))
  }

  @Test func endlessOutputHitsStdoutLimit() async {
    var limited = invocation("/usr/bin/yes")
    limited.stdoutLimit = 64 * 1_024
    await #expect(throws: ScriptToolError.outputTooLarge) {
      _ = try await ScriptToolRunner.run(limited)
    }
  }

  @Test func nonZeroExitReportsStatusAndStderr() async {
    await #expect(throws: ScriptToolError.exitStatus(3, stderr: "oops")) {
      _ = try await ScriptToolRunner.run(invocation("/bin/sh", ["-c", "echo oops >&2; exit 3"]))
    }
  }

  @Test func cancellingTheTaskEndsTheProcess() async throws {
    let started = ContinuousClock.now
    let task = Task { try await ScriptToolRunner.run(invocation("/bin/sleep", ["30"])) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: ScriptToolError.cancelled) { _ = try await task.value }
    #expect(ContinuousClock.now - started < .seconds(3))
  }

  @Test func environmentIsExactlyWhatWasGiven() async throws {
    let output = try await ScriptToolRunner.run(
      invocation("/usr/bin/env", environment: ["PATH": "/usr/bin:/bin", "FOO": "bar baz"]))
    let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    #expect(lines == ["FOO=bar baz", "PATH=/usr/bin:/bin"])
  }

  @Test func scriptThatIgnoresStdinStillSucceeds() async throws {
    // 子进程不读 stdin 就退出：写端拿到 EPIPE 而不是让 Aster 收到 SIGPIPE。
    let big = String(repeating: "x", count: 1_048_576)
    let output = try await ScriptToolRunner.run(invocation("/usr/bin/true", stdin: big))
    #expect(output.stdout.isEmpty)
  }

  @Test func backgroundChildHoldingStdoutDoesNotBlockCompletion() async throws {
    let started = ContinuousClock.now
    let output = try await ScriptToolRunner.run(invocation("/bin/sh", ["-c", "sleep 30 & echo done"]))
    #expect(String(decoding: output.stdout, as: UTF8.self) == "done\n")
    #expect(ContinuousClock.now - started < .seconds(3))
  }

  @Test func nonExecutableFileFailsToLaunch() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("aster-script-\(UUID().uuidString)")
    try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    do {
      _ = try await ScriptToolRunner.run(invocation(file.path))
      Issue.record("不可执行的文件不应启动成功")
    } catch let error as ScriptToolError {
      guard case .launchFailed = error else {
        Issue.record("期望 launchFailed，实际 \(error)")
        return
      }
    }
  }

  @Test func invocationResolvesPluginCommandAndInjectsAsterEnvironment() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-script-plugin-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
    let script = pluginDirectory.appendingPathComponent("bin/run.sh")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nprintf '%s|%s|' \"$ASTER_PLUGIN_ID\" \"$1\"\ncat\n".utf8).write(to: script)
    try makeExecutable(script)
    let action = ToolScriptAction(command: ["bin/run.sh", "a b"], output: .text, stdin: .text)
    let manifest = ToolManifest(
      id: "com.example.script", name: "Script", version: "1.0.0", permissions: [.exec],
      features: [ToolFeature(code: "run", title: "Run", keywords: ["run"], action: .script(action))])
    let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
    let plugin = ToolPluginRuntimeInfo(
      manifest: manifest, source: .user, directory: pluginDirectory, dataDirectory: dataDirectory,
      grantedPermissions: [.exec], grantedNetworkDomains: [])
    let input = ToolInput(text: "payload", source: .typed, context: ToolContext(workingDirectory: root.path))

    let made = try ScriptToolRunner.makeInvocation(
      action: action, code: "run", plugin: plugin, input: input, query: "payload")
    #expect(made.executable.path == canonicalToolPath(script))
    #expect(made.arguments == ["a b"])
    #expect(made.workingDirectory == root.path)
    #expect(made.environment["PATH"] == ScriptToolProtocol.defaultPath)
    #expect(made.environment["ASTER_FEATURE"] == "run")
    #expect(made.environment["ASTER_QUERY"] == "payload")
    #expect(made.environment["ASTER_PLUGIN_DATA"] == dataDirectory.path)
    let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"]
    #expect(made.environment.keys.allSatisfy { allowed.contains($0) || $0.hasPrefix("ASTER_") })
    #expect(FileManager.default.fileExists(atPath: dataDirectory.path))
    let output = try await ScriptToolRunner.run(made)
    #expect(String(decoding: output.stdout, as: UTF8.self) == "com.example.script|a b|payload")
  }

  @Test func commandEscapingThePluginDirectoryIsRejected() throws {
    let manifest = ToolManifest(
      id: "com.example.escape", name: "Escape", version: "1.0.0", permissions: [.exec],
      features: [ToolFeature(code: "run", title: "Run", keywords: ["run"], action: .ui)])
    let plugin = ToolPluginRuntimeInfo(
      manifest: manifest, source: .user, directory: FileManager.default.temporaryDirectory,
      dataDirectory: FileManager.default.temporaryDirectory, grantedPermissions: [.exec], grantedNetworkDomains: [])
    #expect(throws: ScriptToolError.self) {
      _ = try ScriptToolRunner.makeInvocation(
        action: ToolScriptAction(command: ["../../bin/sh"]), code: "run", plugin: plugin, input: ToolInput(),
        query: nil)
    }
  }
}
