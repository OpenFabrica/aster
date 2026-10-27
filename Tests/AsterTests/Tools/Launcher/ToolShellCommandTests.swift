// 脚本工具 `terminal` 输出：argv 与环境变量的转义规则，以及在新本地标签里运行。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("工具命令：每个参数单引号转义，环境变量经 env 按名字排序传入")
func toolShellCommandQuotesArgumentsAndEnvironment() throws {
  #expect(try ToolShellCommand.encode(command: ["ls", "-la", "my dir"], environment: [:]) == "'ls' '-la' 'my dir'")
  #expect(
    try ToolShellCommand.encode(command: ["echo", "it's $(rm -rf ~); `x`"], environment: [:])
      == #"'echo' 'it'\''s $(rm -rf ~); `x`'"#)
  #expect(
    try ToolShellCommand.encode(command: ["./run.sh"], environment: ["ZED": "1", "A_B": "x 'y'"])
      == #"env 'A_B=x '\''y'\''' 'ZED=1' './run.sh'"#)
  // 没有环境变量时不加 env 前缀，可执行文件名里有 = 也没有歧义。
  #expect(try ToolShellCommand.encode(command: ["a=b"], environment: [:]) == "'a=b'")
  // emoji 里的零宽连接符是格式字符，不算控制字符。
  #expect(try ToolShellCommand.encode(command: ["echo", "🧑‍💻"], environment: [:]) == "'echo' '🧑‍💻'")
}

@Test("工具命令：空命令、非法变量名、带 = 的可执行文件与控制字符一律拒绝")
func toolShellCommandRejectsUnsafeInput() {
  typealias Failure = ToolShellCommand.EncodingError
  #expect(throws: Failure.emptyCommand) { try ToolShellCommand.encode(command: [], environment: [:]) }
  #expect(throws: Failure.emptyCommand) { try ToolShellCommand.encode(command: ["", "x"], environment: [:]) }
  for name in ["1X", "A-B", "", "名字"] {
    #expect(throws: Failure.invalidEnvironmentName(name)) {
      try ToolShellCommand.encode(command: ["run"], environment: [name: "v"])
    }
  }
  // env 会把带 = 的第一个参数当成赋值。
  #expect(throws: Failure.invalidEnvironmentName("A=B")) {
    try ToolShellCommand.encode(command: ["A=B"], environment: ["X": "1"])
  }
  for text in ["a\nb", "a\tb", "\u{1B}[A", "a\u{7F}", "a\u{9B}2J", "a\0"] {
    #expect(throws: Failure.controlCharacters) {
      try ToolShellCommand.encode(command: ["echo", text], environment: [:])
    }
  }
  #expect(throws: Failure.controlCharacters) {
    try ToolShellCommand.encode(command: ["run"], environment: ["X": "a\rb"])
  }
  #expect(Failure.invalidEnvironmentName("1X").errorDescription?.contains("1X") == true)
}

@MainActor
@Test("工具命令在新本地标签里运行：目录不存在时退回主目录，命令不合法时只提示不建标签")
func runToolCommandOpensNewLocalTab() throws {
  _ = NSApplication.shared
  let suite = "ToolShellCommand.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let initialCount = model.tabs.count

  model.runToolCommandInNewTab(["echo", "hi"], workingDirectory: directory.path, environment: [:])
  #expect(model.tabs.count == initialCount + 1)
  #expect(model.selectedTab?.layout.allPanes.first?.workingDirectory == directory.path)

  model.runToolCommandInNewTab(
    ["echo"], workingDirectory: directory.appendingPathComponent("missing").path, environment: [:])
  #expect(model.tabs.count == initialCount + 2)
  #expect(
    model.selectedTab?.layout.allPanes.first?.workingDirectory
      == FileManager.default.homeDirectoryForCurrentUser.path)

  model.runToolCommandInNewTab(["echo", "a\u{7}"], workingDirectory: nil, environment: [:])
  #expect(model.tabs.count == initialCount + 2)
  #expect(model.notice == L("命令包含控制字符，已拒绝在终端里运行"))
}
