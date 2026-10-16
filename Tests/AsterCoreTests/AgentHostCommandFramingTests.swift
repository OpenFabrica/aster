import Foundation
import Testing

@testable import AsterCore

/// 把注入行交给真实 Shell 执行（stdin 读入，非交互），返回 stdout。
/// 去掉 Ctrl-U、把 CR 换成 LF：这两处是给交互行编辑器的，非交互 Shell 不认识。
private func runInShell(_ shell: String, _ line: String) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: shell)
  let input = Pipe()
  let output = Pipe()
  process.standardInput = input
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  try process.run()
  let script = line.replacingOccurrences(of: "\u{15}", with: "").replacingOccurrences(of: "\r", with: "\n")
  input.fileHandleForWriting.write(Data((script + "\nexit 0\n").utf8))
  try input.fileHandleForWriting.close()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return String(decoding: data, as: UTF8.self)
}

private let nonce = "0123456789ab"
private let shells = ["/bin/sh", "/bin/bash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }

@Suite("agent 远程执行标记符")
struct AgentHostCommandFramingTests {
  @Test("引号、换行、$、反引号与 Tab 原样到达 Shell", arguments: shells)
  func quotingSurvivesRealShells(shell: String) throws {
    let cases: [(String, String)] = [
      ("printf '%s\\n' \"it's\"", "it's"),
      ("echo 'single '\\''quote'\\'''", "single 'quote'"),
      ("x='$HOME'; printf '%s' \"$x\"", "$HOME"),
      ("printf '%s' '`date`'", "`date`"),
      ("printf 'a\\tb'", "a\tb"),
      ("printf '%s' 'a\tb'", "a\tb"),
      ("printf 'line1\\n'\nprintf 'line2'", "line1\nline2"),
    ]
    for (command, expected) in cases {
      let text = try runInShell(shell, AgentHostCommandFraming.commandLine(command: command, nonce: nonce))
      #expect(AgentHostCommandFraming.parse(text, nonce: nonce) == .completed(exitCode: 0, output: expected, beginSeen: true), "\(shell): \(command)")
    }
  }

  @Test("退出码：0、1、127、130 与语法错误都打印结束标记", arguments: shells)
  func exitCodes(shell: String) throws {
    for (command, code) in [("true", 0), ("false", 1), ("exit_status_missing_cmd_xyz", 127), ("(exit 130)", 130)] {
      let text = try runInShell(shell, AgentHostCommandFraming.commandLine(command: command, nonce: nonce))
      guard case .completed(let exit, _, true) = AgentHostCommandFraming.parse(text, nonce: nonce) else {
        Issue.record("\(shell) \(command): \(text)")
        continue
      }
      #expect(exit == code)
    }
    let syntax = try runInShell(shell, AgentHostCommandFraming.commandLine(command: "if then fi (", nonce: nonce))
    guard case .completed(let exit, _, true) = AgentHostCommandFraming.parse(syntax, nonce: nonce) else {
      Issue.record("语法错误后没有结束标记：\(syntax)")
      return
    }
    #expect(exit != 0)
  }

  @Test("eval 在当前 Shell 执行：cd 与 export 跨命令保留", arguments: shells)
  func stateCarriesAcrossCommands(shell: String) throws {
    let first = AgentHostCommandFraming.commandLine(command: "cd /tmp && export ASTER_T=ok", nonce: nonce)
    let second = AgentHostCommandFraming.commandLine(command: "printf '%s %s' \"$(pwd -P)\" \"$ASTER_T\"", nonce: "ba9876543210")
    let text = try runInShell(shell, first + second)
    guard case .completed(0, let output, true) = AgentHostCommandFraming.parse(text, nonce: "ba9876543210") else {
      Issue.record("\(text)")
      return
    }
    #expect(output.hasSuffix(" ok"))
    #expect(output.contains("tmp"))
  }

  @Test("回显的注入行永远不会被当成标记")
  func echoNeverMatches() {
    let line = AgentHostCommandFraming.commandLine(command: "sleep 5", nonce: nonce)
    let echoed = "user@host:~$ " + line.replacingOccurrences(of: "\u{15}", with: "").replacingOccurrences(of: "\r", with: "")
    #expect(!echoed.contains("<aster:\(nonce)b>"))
    #expect(AgentHostCommandFraming.parse(echoed, nonce: nonce) == .notStarted)
    let probe = AgentHostCommandFraming.probeLine(nonce: nonce, configureEnvironment: true)
    #expect(!AgentHostCommandFraming.containsProbeReply(probe, nonce: nonce))
  }

  @Test("输出无尾换行时结束标记紧跟在输出后面；空输出")
  func noTrailingNewlineAndEmpty() {
    let screen = "$ cmd\n<aster:\(nonce)b>\npartial<aster:\(nonce)e:0>\n$ "
    #expect(AgentHostCommandFraming.parse(screen, nonce: nonce) == .completed(exitCode: 0, output: "partial", beginSeen: true))
    let empty = "$ cmd\n<aster:\(nonce)b>\n<aster:\(nonce)e:3>\n$ "
    #expect(AgentHostCommandFraming.parse(empty, nonce: nonce) == .completed(exitCode: 3, output: "", beginSeen: true))
  }

  @Test("多行命令的 PS2 噪声落在开始标记之前，不进输出")
  func continuationNoiseExcluded() {
    let screen = "$ printf a; eval 'echo 1\n> echo 2'\n<aster:\(nonce)b>\n1\n2\n<aster:\(nonce)e:0>\n$"
    #expect(AgentHostCommandFraming.parse(screen, nonce: nonce) == .completed(exitCode: 0, output: "1\n2", beginSeen: true))
  }

  @Test("开始标记滚出读取范围：返回尾部并标记 beginSeen=false")
  func beginScrolledOut() {
    let screen = "line 998\nline 999\n<aster:\(nonce)e:0>\n$"
    #expect(AgentHostCommandFraming.parse(screen, nonce: nonce) == .completed(exitCode: 0, output: "line 998\nline 999", beginSeen: false))
  }

  @Test("标记中间被插入换行（极窄终端）也能识别")
  func toleratesInsertedNewlines() {
    let screen = "<aster:0123\n456789abb>\nout\n<aster:0123456789\nabe:1\n27>\n"
    #expect(AgentHostCommandFraming.parse(screen, nonce: nonce) == .completed(exitCode: 127, output: "out", beginSeen: true))
  }

  @Test("旧 nonce 的标记被无视；运行中返回已有输出；CR 被去掉")
  func staleNonceIgnoredAndRunning() {
    let stale = "<aster:ffffffffffffb>\nold\n<aster:ffffffffffffe:0>\n"
    #expect(AgentHostCommandFraming.parse(stale, nonce: nonce) == .notStarted)
    let running = stale + "<aster:\(nonce)b>\r\nstep 1\r\nstep 2"
    #expect(AgentHostCommandFraming.parse(running, nonce: nonce) == .running(output: "step 1\nstep 2"))
  }

  @Test("就绪探针回应识别；非法 nonce 一律不匹配")
  func probeReply() {
    #expect(AgentHostCommandFraming.containsProbeReply("$ x\n<aster:\(nonce):ready>\n$", nonce: nonce))
    #expect(!AgentHostCommandFraming.containsProbeReply("<aster:\(nonce):ready>", nonce: "zz"))
    #expect(AgentHostCommandFraming.parse("<aster:zzb>", nonce: "zz") == .notStarted)
    #expect(AgentHostCommandFraming.isValidNonce(AgentHostCommandFraming.makeNonce()))
  }

  @Test("就绪探针在真实 Shell 中打印回应", arguments: shells)
  func probeRunsInShell(shell: String) throws {
    let text = try runInShell(shell, AgentHostCommandFraming.probeLine(nonce: nonce, configureEnvironment: true))
    #expect(AgentHostCommandFraming.containsProbeReply(text, nonce: nonce))
  }

  @Test("截断保留开头与结尾，按字符边界切，不切坏多字节字符")
  func truncation() {
    let text = String(repeating: "a", count: 100) + String(repeating: "中", count: 100) + String(repeating: "z", count: 100)
    let result = AgentHostCommandFraming.truncate(text, maximumBytes: 120, headBytes: 40)
    #expect(result.truncated)
    #expect(result.text.hasPrefix(String(repeating: "a", count: 40)))
    #expect(result.text.hasSuffix(String(repeating: "z", count: 80)))
    #expect(result.text.contains("bytes omitted"))
    let short = AgentHostCommandFraming.truncate("短", maximumBytes: 10)
    #expect(short.text == "短" && !short.truncated)
    let cjk = AgentHostCommandFraming.truncate(String(repeating: "中", count: 50), maximumBytes: 20, headBytes: 7)
    #expect(!cjk.text.contains("\u{FFFD}"))
  }

  @Test("命令校验：拒绝 NUL、ESC、CR，限制总长与单行长度")
  func validation() {
    #expect(throws: AsterControlError.self) { try AgentHostCommandFraming.validate(command: "  \n ") }
    #expect(throws: AsterControlError.self) { try AgentHostCommandFraming.validate(command: "a\u{1B}[A") }
    #expect(throws: AsterControlError.self) { try AgentHostCommandFraming.validate(command: "a\rb") }
    #expect(throws: AsterControlError.self) { try AgentHostCommandFraming.validate(command: "a\u{0}") }
    #expect(throws: AsterControlError.self) {
      try AgentHostCommandFraming.validate(command: String(repeating: "x", count: AgentHostLimits.maximumCommandLineBytes + 1))
    }
    #expect(throws: Never.self) { try AgentHostCommandFraming.validate(command: "echo a\n\techo b") }
  }
}
