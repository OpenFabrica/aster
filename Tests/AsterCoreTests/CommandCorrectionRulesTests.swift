import Foundation
import Testing

@testable import AsterCore

private func corrections(
  _ command: String, output: String, exitStatus: Int? = 1,
  known: Set<String> = ["git", "npm", "ls"],
  directories: [String: [String]] = [:],
  files: Set<String> = []
) -> [CommandCorrection] {
  CommandCorrectionParser.suggestions(
    command: command, output: output,
    context: CommandCorrectionContext(
      exitStatus: exitStatus, knownCommands: known,
      directoryEntries: { directories[$0] ?? [] },
      fileExists: { files.contains($0) }))
}

@Test("git push 被远端拒绝时建议先 pull --rebase，强推不建议")
func correctionSuggestsPullBeforePush() {
  let output = """
    ! [rejected]        main -> main (fetch first)
    error: failed to push some refs to 'origin'
    hint: Updates were rejected because the remote contains work that you do not
    """
  #expect(
    corrections("git push origin main", output: output).first
      == CommandCorrection(command: "git pull --rebase && git push origin main", kind: .pullBeforePush))
  #expect(
    corrections("git push", output: "hint: Updates were rejected because the tip of your current branch is behind").first?.kind
      == .pullBeforePush)
  #expect(corrections("git push --force", output: output).isEmpty)
  #expect(corrections("git push -f origin main", output: output).isEmpty)
}

@Test("分支已存在时按原动词改为切换")
func correctionSwitchesToExistingBranch() {
  #expect(
    corrections("git checkout -b feature/x", output: "fatal: a branch named 'feature/x' already exists").first
      == CommandCorrection(command: "git checkout feature/x", kind: .switchExistingBranch))
  #expect(
    corrections("git switch -c release", output: "fatal: A branch named 'release' already exists.").first
      == CommandCorrection(command: "git switch release", kind: .switchExistingBranch))
  // 分支名带控制字符或奇怪引号时不生成建议，避免把终端输出当命令。
  #expect(corrections("git switch -c x", output: "fatal: a branch named 'a;rm' already exists").isEmpty)
}

@Test("cd 到不存在的目录时在父目录里找最接近的目录名")
func correctionFindsNearestDirectory() {
  let directories = ["": ["project", "notes", "Library"], "src": ["components", "utils"]]
  #expect(
    corrections("cd porject", output: "cd: no such file or directory: porject", directories: directories).first
      == CommandCorrection(command: "cd project", kind: .nearestDirectory))
  #expect(
    corrections("cd porject", output: "bash: cd: porject: No such file or directory", directories: directories).first?.command
      == "cd project")
  #expect(
    corrections("cd porject", output: "cd: The directory 'porject' does not exist", directories: directories).first?.command
      == "cd project")
  #expect(
    corrections("cd src/utisl", output: "cd: no such file or directory: src/utisl", directories: directories).first?.command
      == "cd src/utils")
  // 距离太远不乱猜；目录不存在于列表也不猜。
  #expect(corrections("cd zzzzzzzz", output: "cd: no such file or directory: zzzzzzzz", directories: directories).isEmpty)
  #expect(corrections("cd porject", output: "cd: no such file or directory: porject").isEmpty)
  // 含空格的目录名要加引号。
  #expect(
    corrections("cd myproj", output: "cd: no such file or directory: myproj", directories: ["": ["my proj"]]).first?.command
      == "cd 'my proj'")
}

@Test("Terraform 未初始化时先 init 再重试")
func correctionPrependsTerraformInit() {
  #expect(
    corrections("terraform plan -var-file=prod.tfvars", output: "Error: Initialization required.").first
      == CommandCorrection(command: "terraform init && terraform plan -var-file=prod.tfvars", kind: .terraformInit))
  #expect(corrections("tofu apply", output: "Backend reinitialization required").first?.command == "tofu init && tofu apply")
  #expect(corrections("terraform init", output: "Initialization required").isEmpty)
}

@Test("权限不足时建议 sudo，但不对 ssh 认证失败、管道或已 sudo 的命令建议")
func correctionElevatesPrivileges() {
  #expect(
    corrections("apt install ripgrep", output: "E: Could not open lock file - open (13: Permission denied)").first
      == CommandCorrection(command: "sudo apt install ripgrep", kind: .elevatePrivileges))
  #expect(corrections("sudo apt install ripgrep", output: "Permission denied").isEmpty)
  #expect(corrections("cat /etc/shadow | grep root", output: "cat: /etc/shadow: Permission denied").isEmpty)
  #expect(corrections("ssh host", output: "host: Permission denied (publickey).").isEmpty)
  #expect(corrections("rm -rf build", output: "rm: build/x: Permission denied", exitStatus: 0).isEmpty)
}

@Test("命令名拼写纠错保留参数，且不把同名命令当成纠错")
func correctionFixesCommandTypo() {
  #expect(
    corrections("gti status", output: "zsh: command not found: gti").first
      == CommandCorrection(command: "git status", kind: .typoCommand))
  #expect(corrections("git status", output: "zsh: command not found: git").isEmpty)
}

@Test("多条建议按确定性排序、去重并限制数量")
func correctionOrdersAndDeduplicates() {
  // 工具明说的子命令更正排在命令名猜测之前；sudo 永远最后。
  let output = "git: 'statsu' is not a git command.\n\nThe most similar command is\n\tstatus\nPermission denied"
  let result = corrections("git statsu", output: output)
  #expect(result.map(\.kind) == [.typoSubcommand])
  let elevated = corrections("make install", output: "install: cannot create regular file: Permission denied")
  #expect(elevated.map(\.kind) == [.elevatePrivileges])
  #expect(result.count <= CommandCorrectionParser.maximumSuggestions)
}

@Test("编辑距离工具按距离再按字典序选取最接近项")
func editDistancePicksNearestDeterministically() {
  #expect(StringEditDistance.levenshtein("kitten", "sitting") == 3)
  #expect(StringEditDistance.levenshtein("", "abc") == 3)
  #expect(StringEditDistance.nearest(to: "porject", in: ["project", "projects", "notes"], maximumDistance: 3) == "project")
  #expect(StringEditDistance.nearest(to: "ab", in: ["ac", "ad"], maximumDistance: 1) == "ac")
  #expect(StringEditDistance.nearest(to: "ab", in: ["xyz"], maximumDistance: 1) == nil)
  #expect(StringEditDistance.correctionTolerance(for: "ab") == 1)
  #expect(StringEditDistance.correctionTolerance(for: "abcdefghijkl") == 3)
}
