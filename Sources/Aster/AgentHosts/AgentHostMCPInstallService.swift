// 把 `aster mcp`（agent 远程执行的 MCP server）注册进 Claude Code / Codex 的用户级配置。
// 走各自的官方命令（`claude mcp add --scope user`、`codex mcp add`），不直接改它们的配置文件；
// 命令找不到或失败时给出可复制的片段，由用户自己粘贴。
import AsterCore
import Darwin
import Foundation

/// MCP 一键安装。
enum AgentHostMCPInstallService {
  /// 支持的客户端。
  enum Client: String, CaseIterable, Sendable {
    case claude
    case codex

    /// 客户端的可执行文件名。
    var executableName: String { rawValue }
  }

  /// 安装结果。失败时 `snippet` 是让用户手动配置的片段。
  struct Outcome: Equatable, Sendable {
    var succeeded: Bool
    var message: String
    var snippet: String?
  }

  static let serverName = "aster"
  /// 单条命令的等待上限：Claude CLI 是 node 程序，冷启动可能要几秒。
  static let commandTimeout: TimeInterval = 30

  /// MCP 配置里写的 CLI 路径：优先 `aster` 稳定 symlink（App 升级、移动后仍有效），
  /// 没装 symlink 时退回 App 内的 `aster-cli`。
  static func cliPath() -> String? {
    if case .installed(let path) = AsterCLIInstaller.state() { return path }
    return AsterCLIInstaller.resolveExecutableURL()?.path
  }

  /// 手动配置片段。
  static func snippet(for client: Client, cliPath: String) -> String {
    switch client {
    case .claude:
      "claude mcp add --scope user \(serverName) -- \(RemoteSSHInvocation.quote(cliPath)) mcp"
    case .codex:
      "[mcp_servers.\(serverName)]\ncommand = \"\(cliPath.replacingOccurrences(of: "\"", with: "\\\""))\"\nargs = [\"mcp\"]"
    }
  }

  /// 在后台执行安装。先 remove 再 add，使重复安装（例如 App 移动后）也能覆盖旧路径。
  static func install(_ client: Client, locator: AgentExecutableLocator) async -> Outcome {
    guard let cli = cliPath() else {
      return Outcome(succeeded: false, message: L("找不到 aster-cli 可执行文件，请先在设置里安装 aster 命令。"), snippet: nil)
    }
    let snippet = snippet(for: client, cliPath: cli)
    guard let executable = locator.path(for: client.executableName) else {
      return Outcome(
        succeeded: false, message: L("没有找到 \(client.executableName) 命令，已复制手动配置片段。"), snippet: snippet)
    }
    let search = locator.searchDirectories.map(\.path)
    let status = await Task.detached(priority: .userInitiated) { () -> Int32? in
      // Claude 要显式写用户级作用域，否则默认装进当前目录的项目配置；Codex 只有全局配置。
      let scope: [String] = client == .claude ? ["--scope", "user"] : []
      _ = run(executable, ["mcp", "remove"] + scope + [serverName], searchPath: search)
      return run(executable, ["mcp", "add"] + scope + [serverName, "--", cli, "mcp"], searchPath: search)
    }.value
    guard status == 0 else {
      return Outcome(
        succeeded: false, message: L("\(client.executableName) mcp add 没有成功，已复制手动配置片段。"), snippet: snippet)
    }
    return Outcome(succeeded: true, message: L("已把 Aster 主机访问注册到 \(client.executableName)。"), snippet: nil)
  }

  /// 有界执行一条命令，返回退出码；超时或启动失败返回 nil。输出丢弃：可能含用户配置内容。
  ///
  /// PATH 换成定位器的搜索目录：`claude` 是 `#!/usr/bin/env node` 脚本，GUI 进程的精简 PATH 找不到 node。
  nonisolated static func run(_ executable: String, _ arguments: [String], searchPath: [String]) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = (searchPath + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do { try process.run() } catch { return nil }
    guard finished.wait(timeout: .now() + commandTimeout) == .success else {
      process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut, process.processIdentifier > 0 {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
      }
      return nil
    }
    return process.terminationReason == .exit ? process.terminationStatus : nil
  }
}
