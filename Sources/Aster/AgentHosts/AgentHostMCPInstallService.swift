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

  /// MCP 配置里写的命令路径：只用 PATH 里的 `aster` 稳定 symlink，从不写 App 包内的绝对路径。
  /// 包内路径会随开发构建删除、App 移动或换装正式版而失效，Claude Code / Codex 启动时就会报错；
  /// symlink 路径不变，由「安装 aster 命令」负责指向当前 App。未安装（或只有旧 sh 脚本）时返回 nil。
  static func stableCommandPath(directories: [String] = AsterCLIInstaller.defaultDirectories()) -> String? {
    switch AsterCLIInstaller.state(directories: directories) {
    case .installed(let path), .outdated(let path, _): path
    case .notInstalled, .legacyScript: nil
    }
  }

  /// 取稳定命令路径；还没装 `aster` 命令时先装 symlink 再返回。失败返回面向用户的错误描述。
  static func ensureStableCommandPath(
    directories: [String] = AsterCLIInstaller.defaultDirectories(), executableURL: URL? = nil
  ) -> Result<String, InstallError> {
    if let path = stableCommandPath(directories: directories) { return .success(path) }
    do {
      return .success(try AsterCLIInstaller.install(directories: directories, executableURL: executableURL))
    } catch let error as AsterCLIInstaller.ServiceError {
      return .failure(InstallError(message: error.localizedMessage))
    } catch {
      return .failure(InstallError(message: L("安装 aster 命令失败。")))
    }
  }

  /// 准备命令路径失败的原因（已本地化）。
  struct InstallError: Error, Equatable {
    var message: String
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
    let cli: String
    switch ensureStableCommandPath() {
    case .success(let path): cli = path
    case .failure(let error): return Outcome(succeeded: false, message: error.message, snippet: nil)
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
    // symlink 指向别的 Aster（例如 /Applications 里的旧正式版）时照样注册稳定路径，但提醒用户：
    // 那个版本要支持 `aster mcp`，否则在设置里重新安装 aster 命令让它指向当前 App。
    if case .outdated = AsterCLIInstaller.state() {
      return Outcome(
        succeeded: true,
        message: L("已注册到 \(client.executableName)，命令为 \(cli)。它目前指向另一个 Aster；该版本需支持 aster mcp，否则请重新安装 aster 命令。"),
        snippet: nil)
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
