import AsterCore
import Foundation
import Testing

@testable import Aster

private let dynamicFixtureDatabase = AutocompleteSpecDatabase(sourceRevision: "test", commands: [
  AutocompleteCommandSpec(name: "git", subcommands:
    ["checkout", "switch", "merge", "rebase", "cherry-pick", "branch", "tag", "log", "show", "reset",
      "add", "restore", "diff", "push", "pull", "fetch"].map { AutocompleteCommandSpec(name: $0) }
    + [AutocompleteCommandSpec(name: "stash", subcommands:
      ["apply", "drop", "show", "pop", "list"].map { AutocompleteCommandSpec(name: $0) })]),
  AutocompleteCommandSpec(name: "npm", subcommands:
    ["run", "run-script", "exec", "x", "dlx", "install"].map { AutocompleteCommandSpec(name: $0) }),
  AutocompleteCommandSpec(name: "yarn", subcommands:
    ["run", "run-script", "exec", "dlx", "install"].map { AutocompleteCommandSpec(name: $0) }),
])

private func dynamicContext(_ line: String) -> AutocompleteDynamicContext {
  AutocompleteDynamicContext(line: line, directory: "/tmp", specifications: dynamicFixtureDatabase,
    deadline: ContinuousClock.now.advanced(by: .seconds(3)))
}

@Test("原生Git按子命令、精确flag和位置选择固定来源")
func autocompleteNativeDynamicGitRouting() {
  typealias S = AutocompleteGitDynamic.Source
  let cases: [(String, [S])] = [
    ("git checkout ", [.branches, .remoteBranches, .tags]),
    ("git reset ", [.staged, .branches]), ("git add ", [.status]),
    ("git branch ", []), ("git branch -D ", [.branches]), ("git branch -dv ", []),
    ("git tag --delete ", [.tags]), ("git tag --delete=yes ", []),
    ("git restore ", [.unstaged]), ("git restore -S ", [.staged]),
    ("git diff ", [.unstaged, .branches]), ("git diff --cached ", [.staged]),
    ("git push ", [.remotes]), ("git push origin ", [.branches]), ("git push origin main ", []),
    ("git fetch --prune or", [.remotes]), ("git stash pop ", [.stashes]), ("git stash list ", []),
  ]
  for (line, expected) in cases {
    #expect(AutocompleteGitDynamic.sources(context: dynamicContext(line)) == expected)
  }
  #expect(S.status.arguments == ["git", "--no-optional-locks", "status", "--short"])
}

@Test("Git分支输出保留顺序并变换远端名称、忽略符号HEAD")
func autocompleteNativeDynamicGitBranches() {
  let local = AutocompleteGitDynamic.parse("* main\n  feature/topic\n  (HEAD detached at abc)\n", source: .branches)
  #expect(local.map(\.name) == ["main", "feature/topic"])
  let remote = AutocompleteGitDynamic.parse("origin/HEAD -> origin/main\n origin/feature/topic\nupstream/main", source: .remoteBranches)
  #expect(remote.map(\.name) == ["feature/topic", "main"])
  #expect(remote.map(\.description) == ["origin/feature/topic", "upstream/main"])
  #expect(remote.allSatisfy { $0.kind == .argument && !$0.clearLeader })
}

@Test("Git status仅含未暂存项，使用原生状态描述及重命名目标")
func autocompleteNativeDynamicGitStatus() {
  let output = "?? new.txt\n M changed.txt\nM  only-staged.txt\nMM partial.txt\nAM added.txt\n D gone.txt\nRM old -> \"new name\""
  let items = AutocompleteGitDynamic.parse(output, source: .status)
  #expect(items.map(\.name) == ["new.txt", "changed.txt", "partial.txt", "added.txt", "gone.txt", "new name"])
  #expect(items.map(\.description) == ["untracked", "modified", "modified (partially staged)", "added, then modified", "deleted", "RM"])
  #expect(items.allSatisfy { $0.kind == .file })
  #expect(AutocompleteGitDynamic.parse("stash@{0}: On main: work", source: .stashes).first?.description == "On main: work")
}

@Test("npm读取最近manifest的字符串scripts，错误不回退父manifest且不执行内容")
func autocompleteNativeDynamicPackageScripts() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let child = root.appendingPathComponent("child")
  try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
  try #"{"scripts":{"z":"touch must-not-exist","a":"echo start","ignored":2}}"#
    .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
  let provider = AutocompleteNativeDynamicProvider()
  let items = await provider.candidates(line: "npm run ", directory: child.path,
    executables: [], specifications: dynamicFixtureDatabase)
  #expect(items.map(\.name) == ["a", "z"])
  #expect(items.last?.description == "touch must-not-exist")
  #expect(!FileManager.default.fileExists(atPath: child.appendingPathComponent("must-not-exist").path))
  #expect(await provider.candidates(line: "yarn run-script ", directory: child.path,
    executables: [], specifications: dynamicFixtureDatabase).isEmpty)
  #expect(await provider.candidates(line: "yarn ", directory: child.path,
    executables: [], specifications: dynamicFixtureDatabase).map(\.name) == ["a", "z"])
  try "invalid".write(to: child.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
  #expect(await provider.candidates(line: "npm run ", directory: child.path, executables: [],
    specifications: dynamicFixtureDatabase).isEmpty)
}

@Test("npx仅枚举当前node_modules/.bin且不要求文件可执行")
func autocompleteNativeDynamicLocalBinaries() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let binaries = root.appendingPathComponent("node_modules/.bin")
  try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
  for name in ["vite", "tsc", ".hidden"] {
    try "not executable".write(to: binaries.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  let items = await AutocompleteNativeDynamicProvider().candidates(line: "npx ", directory: root.path, executables: [])
  #expect(items.map(\.name) == ["tsc", "vite"])
  #expect(items.allSatisfy { $0.description == "bin" })
}

@Test("Make选择GNUmakefile优先，PHONY和普通target按首次出现去重")
func autocompleteNativeDynamicMakefile() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let content = """
    # ignored
    .PHONY: clean all .hidden
    all test: deps
    %.o: %.c
    $(OUTPUT): deps
    VAR = value: not-target
    .SUFFIXES: .c
    \trecipe: nope
    """
  try content.write(to: root.appendingPathComponent("GNUmakefile"), atomically: true, encoding: .utf8)
  try "other: dep".write(to: root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
  let items = await AutocompleteNativeDynamicProvider().candidates(line: "make ", directory: root.path, executables: [])
  #expect(items.map(\.name) == ["clean", "all", "test"])
}

@Test("Compose按第一层服务缩进扫描，不展开内联映射或后续顶层节点")
func autocompleteNativeDynamicComposeServices() {
  #expect(AutocompleteNativeDynamicProvider.composeServices("""
    services:
      web:
        image: nginx
      worker:
        environment:
          MODE: test
      inline: { image: nginx }
    volumes:
      data:
    """) == ["web", "worker"])
}

@Test("当前快照的docker compose缺少子命令链，只有docker-compose进入服务来源")
func autocompleteNativeDynamicComposeRequiresParsedSubcommand() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try "services:\n  web:\n    image: example.invalid/synthetic\n  worker:\n    image: example.invalid/synthetic\n"
    .write(to: root.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
  let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let database = try AutocompleteSpecStore.decode(Data(contentsOf:
    repository.appendingPathComponent("Resources/autocomplete/fig-specs.json")))
  let provider = AutocompleteNativeDynamicProvider()
  let incomplete = await provider.candidates(line: "docker compose up ", directory: root.path,
    executables: [], specifications: database)
  #expect(incomplete.isEmpty)
  let standalone = await provider.candidates(line: "docker-compose up ", directory: root.path,
    executables: [], specifications: database)
  #expect(standalone.map(\.name) == ["web", "worker"])
  // 补齐规格链后同一个分派器即可进入；不能在缺失规格时自行用 raw tokens 代替。
  let complete = AutocompleteSpecDatabase(sourceRevision: "fixture", commands: [
    .init(name: "docker", subcommands: [.init(name: "compose", subcommands: [.init(name: "up")])]),
  ])
  let nested = await provider.candidates(line: "docker compose up ", directory: root.path,
    executables: [], specifications: complete)
  #expect(nested.map(\.name) == ["web", "worker"])
}

@Test("which只在首个参数位置枚举命令，已取消查询为空")
func autocompleteNativeDynamicWhichAndCancellation() async {
  let provider = AutocompleteNativeDynamicProvider()
  #expect(await provider.candidates(line: "which --all g", directory: "", executables: ["zsh", "git"])
    .map(\.name) == ["git", "zsh"])
  #expect(await provider.candidates(line: "which git ", directory: "", executables: ["zsh"]).isEmpty)
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return await provider.candidates(line: "which ", directory: "", executables: ["git"])
  }
  #expect(await task.value.isEmpty)
}

@Test("动态进程保留字面argv，非零/超时/输出越界都丢弃")
func autocompleteNativeDynamicProcessFailures() {
  var process = AutocompleteDynamicProcess(environment: ["PATH": "/usr/bin:/bin"])
  #expect(process.run(arguments: ["printf", "%s", "$(touch no-command-execution)"], directory: "/tmp", timeout: 1)
    == "$(touch no-command-execution)")
  #expect(process.run(arguments: ["false"], directory: "/tmp", timeout: 1) == nil)
  #expect(process.run(arguments: ["sleep", "1"], directory: "/tmp", timeout: 0.03) == nil)
  process.maximumOutputBytes = 10
  #expect(process.run(arguments: ["printf", "%s", "elevenbytes!"], directory: "/tmp", timeout: 1) == nil)
}

@Test("Cargo保留manifest声明顺序，features排除default，members保留原路径")
func autocompleteNativeDynamicCargoManifest() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try """
    [package]
    name = "root-package"
    [[bin]]
    name = 'z-tool'
    [[bin]]
    name = "a-tool"
    [features]
    zeta = []
    default = ["zeta"]
    alpha = []
    [workspace]
    members = ["crates/*", "utils/helper"]
    [[bench]]
    name = "speed"
    """.write(to: root.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
  let provider = AutocompleteNativeDynamicProvider()
  #expect(await provider.candidates(line: "cargo run --bin ", directory: root.path, executables: [])
    .map(\.name) == ["z-tool", "a-tool"])
  #expect(await provider.candidates(line: "cargo build -F ", directory: root.path, executables: [])
    .map(\.name) == ["zeta", "alpha"])
  #expect(await provider.candidates(line: "cargo build -p ", directory: root.path, executables: [])
    .map(\.name) == ["crates/*", "utils/helper"])
  #expect(await provider.candidates(line: "cargo bench --bench ", directory: root.path, executables: [])
    .map(\.name) == ["speed"])
  #expect(await provider.candidates(line: "cargo run --bin=", directory: root.path, executables: []).isEmpty)
  #expect(AutocompleteCargoManifest("[workspace]\nmembers = prefix[\"ignored\"]").members.isEmpty)
}

@Test("Cargo bin空时回退包名，examples来自当前目录且不限定.rs或文件类型")
func autocompleteNativeDynamicCargoFallbackAndExamples() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try "[package]\nname = \"fallback\"".write(to: root.appendingPathComponent("Cargo.toml"),
    atomically: true, encoding: .utf8)
  let examples = root.appendingPathComponent("examples")
  try FileManager.default.createDirectory(at: examples.appendingPathComponent("directory"), withIntermediateDirectories: true)
  for name in ["z.rs", "note.txt", ".hidden.rs"] {
    try "".write(to: examples.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  let provider = AutocompleteNativeDynamicProvider()
  #expect(await provider.candidates(line: "cargo run --bin ", directory: root.path, executables: [])
    .map(\.name) == ["fallback"])
  #expect(await provider.candidates(line: "cargo run --example ", directory: root.path, executables: [])
    .map(\.name) == ["directory", "note.txt", "z"])
}

@Test("SSH首host位置和精确取值flag遵守原生扫描，不扩展为任意参数槽")
func autocompleteNativeDynamicSSHPositionAndKnownHosts() {
  #expect(AutocompleteNativeDynamicProvider.isSSHHostPosition(dynamicContext("ssh -p ")))
  #expect(AutocompleteNativeDynamicProvider.isSSHHostPosition(dynamicContext("ssh -p 22 us")))
  #expect(!AutocompleteNativeDynamicProvider.isSSHHostPosition(dynamicContext("scp local ")))
  #expect(!AutocompleteNativeDynamicProvider.isSSHHostPosition(dynamicContext("ssh host ")))
  #expect(AutocompleteNativeDynamicProvider.knownSSHHosts("""
    # ignored
    |1|hashed key
    @cert-authority alpha,[beta]:2222 ssh-ed25519 key
    gamma,alpha,!denied,*.wild,maybe? key
    [unfinished key
    """) == ["alpha", "beta", "gamma", "unfinished"])
}

@Test("SSH包含文件先序读取、深度三层，字面#与单引号保留，config优先去重")
func autocompleteNativeDynamicSSHIncludes() async throws {
  let root = try completionTestDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let ssh = root.appendingPathComponent(".ssh")
  try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
  let contents = [
    "config": "Host root # note\nInclude child.conf\nHost after\nHost \"two words\" 'literal'",
    "child.conf": "Host child\nInclude grand.conf",
    "grand.conf": "Host grand\nInclude deep.conf",
    "deep.conf": "Host excluded",
    "known_hosts": "root key\nknown key",
  ]
  for (name, content) in contents {
    try content.write(to: ssh.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  var provider = AutocompleteNativeDynamicProvider(environment: ["HOME": root.path])
  provider.recentSSHHosts = ["root", "recent"]
  let items = await provider.candidates(line: "ssh user@", directory: root.path, executables: [])
  #expect(items.map(\.name) == ["user@root", "user@#", "user@note", "user@child", "user@grand",
    "user@after", "user@two words", "user@'literal'", "user@known", "user@recent"])
  #expect(items.first?.description == "ssh config")
  #expect(items.suffix(2).map(\.description) == ["known host", "recent"])
}
