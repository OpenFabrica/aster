import Foundation
import Testing

@testable import AsterCore

private func runner(_ line: String, files: Set<String>) -> CommandCorrection? {
  let command = ShellCommandTokenizer.tokenize(line).tokens.first ?? ""
  return PackageRunnerSuggestion.suggestion(command: command, commandLine: line) { files.contains($0) }
}

@Test("项目 node_modules/.bin 里有该命令时按锁文件选运行器")
func packageRunnerUsesProjectBinaries() {
  #expect(
    runner("vite --port 3000", files: ["node_modules/.bin/vite", "package-lock.json"])
      == CommandCorrection(command: "npx vite --port 3000", kind: .packageRunner(runner: "npx")))
  #expect(runner("vite", files: ["node_modules/.bin/vite", "pnpm-lock.yaml"])?.command == "pnpm exec vite")
  #expect(runner("vite", files: ["node_modules/.bin/vite", "bun.lockb"])?.command == "bunx vite")
  // 子目录里也能找到上层项目的 .bin。
  #expect(runner("my-tool run", files: ["../../node_modules/.bin/my-tool", "../../yarn.lock"])?.command == "yarn my-tool run")
}

@Test("已知 npm / PyPI / gem CLI 没有项目标记时用临时运行器，未知名字不猜")
func packageRunnerFallsBackToKnownTables() {
  #expect(runner("prettier --write .", files: [])?.command == "npx prettier --write .")
  #expect(runner("prettier --write .", files: ["pnpm-lock.yaml"])?.command == "pnpm dlx prettier --write .")
  #expect(runner("ruff check src", files: [])?.command == "uvx ruff check src")
  #expect(runner("ruff check src", files: ["uv.lock"])?.command == "uv run ruff check src")
  #expect(runner("pytest -q", files: ["poetry.lock"])?.command == "poetry run pytest -q")
  #expect(runner("rubocop -a", files: ["Gemfile"])?.command == "bundle exec rubocop -a")
  #expect(runner("rubocop -a", files: []) == nil)
  #expect(runner("gti status", files: []) == nil)
  #expect(runner("./script.sh", files: []) == nil)
}

@Test("包运行器建议只在 command not found 时进入纠错列表，排在拼写纠错之后")
func packageRunnerIsOrderedAfterTypoCorrection() {
  let context = CommandCorrectionContext(
    exitStatus: 127, knownCommands: ["git", "prettier"],
    fileExists: { _ in false })
  let result = CommandCorrectionParser.suggestions(
    command: "prettier --check .", output: "zsh: command not found: prettier", context: context)
  #expect(result.map(\.kind) == [.packageRunner(runner: "npx")])
  let failed = CommandCorrectionParser.suggestions(
    command: "prettier --check .", output: "[error] No parser could be inferred",
    context: CommandCorrectionContext(exitStatus: 2))
  #expect(failed.isEmpty)
}
