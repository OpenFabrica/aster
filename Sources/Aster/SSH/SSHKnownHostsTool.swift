import AsterCore
import Foundation

// `aster-ssh known-hosts list|remove` 的调用封装：编码请求、按子命令约定解释退出码与错误 JSON。
// 运行进程、超时与输出上限由 `SSHRuntimeTool` 负责。

/// known-hosts 子命令的失败。
enum SSHKnownHostsToolError: Error, Equatable {
  /// 记录在列出之后被改过（退出码 3）；应重新列出后再操作。
  case stale
  /// 子命令报告的失败（退出码 1），值是约定的错误名（`global`、`notWritable`、`noMatch` 等）。
  case failed(String)
  /// 输出不是约定的 JSON。
  case malformedOutput
}

extension SSHRuntimeTool {
  /// 列出 known_hosts 记录。
  func listKnownHosts(_ request: SSHKnownHostsListRequest) async throws -> SSHKnownHostsListing {
    let output = try await knownHostsCall("list", request)
    do { return try JSONDecoder().decode(SSHKnownHostsListing.self, from: output) } catch {
      throw SSHKnownHostsToolError.malformedOutput
    }
  }

  /// 删除一条 known_hosts 记录或其中一个主机模式。
  func removeKnownHost(_ request: SSHKnownHostsRemoveRequest) async throws -> SSHKnownHostsRemoveResult {
    let output = try await knownHostsCall("remove", request)
    do { return try JSONDecoder().decode(SSHKnownHostsRemoveResult.self, from: output) } catch {
      throw SSHKnownHostsToolError.malformedOutput
    }
  }

  /// 运行 `aster-ssh known-hosts <subcommand>`：退出码 3 映射为 `.stale`，1 映射为带错误名的 `.failed`。
  private func knownHostsCall(_ subcommand: String, _ request: some Encodable) async throws -> Data {
    let input = try JSONEncoder().encode(request)
    do {
      return try await run(["known-hosts", subcommand], input: input)
    } catch SSHRuntimeToolError.exited(let code, let stdout) {
      if code == 3 { throw SSHKnownHostsToolError.stale }
      let object = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
      throw SSHKnownHostsToolError.failed(object?["error"] as? String ?? "exit \(code)")
    }
  }
}
