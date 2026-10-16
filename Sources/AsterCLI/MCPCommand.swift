// `aster mcp`：stdio MCP server，把编程 agent 的工具调用转成 `host.*` 控制请求。
// 逐行读 stdin 的 JSON-RPC、逐行写 stdout；协议逻辑在 AsterCore 的 AgentHostMCPTools。
import AsterCore
import Foundation

/// `aster mcp` 的入口与 IO 循环。
enum MCPCommand {
  /// 判断 argv 是否为 `aster mcp`。
  static func matches(_ argv: [String]) -> Bool {
    argv.first == "mcp"
  }

  /// 运行 stdio 循环直到 stdin 关闭。stdout 只能写 JSON-RPC，诊断信息一律走 stderr。
  ///
  /// 循环是同步的：一次 tools/call 阻塞到控制请求返回。工具把单次等待限制在 50 s 内，
  /// 所以不会长时间挡住后续请求；`notifications/cancelled` 只能在调用间隙被丢弃。
  static func run(_ argv: [String], explicitSocket: String?, environment: [String: String]) -> Never {
    guard argv.count == 1 else {
      writeStandardError("aster: mcp 不接受额外参数：\(argv.dropFirst().joined(separator: " "))\n")
      exit(AsterCLIExitCode.usage)
    }
    // 会话键在进程启动时生成一次：同一个 MCP server 进程（即同一个 agent 会话）的调用
    // 共用授权与终端；新进程是新会话，需要重新批准。
    var tools = AgentHostMCPTools(
      sessionKey: "mcp:\(UUID().uuidString.lowercased())", callerPane: environment["ASTER_PANE_ID"])
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let call: AgentHostMCPTools.ControlCall = { method, params in
      try controlCall(method: method, params: params, explicitSocket: explicitSocket, environment: environment)
    }

    while let line = readLine(strippingNewline: true) {
      guard !line.isEmpty else { continue }
      guard let request = try? decoder.decode(JSONRPCRequest.self, from: Data(line.utf8)) else {
        emit(JSONRPCResponse(id: nil, error: JSONRPCError(code: -32700, message: "parse error")), encoder: encoder)
        continue
      }
      if let response = tools.handle(request, call: call) {
        emit(response, encoder: encoder)
      }
    }
    exit(AsterCLIExitCode.success)
  }

  /// 每次调用新建一条连接：App 可能在两次调用之间重启，长连接会指向已失效的 socket。
  /// 等待类方法的客户端超时 = 服务端等待时长 + 15 s 余量，避免客户端先于服务端放弃。
  static func controlCall(
    method: String, params: JSONValue, explicitSocket: String?, environment: [String: String]
  ) throws -> JSONValue {
    do {
      let client = ControlClient(
        socketPath: try ControlClient.resolveSocketPath(explicit: explicitSocket, environment: environment),
        environment: environment)
      return try client.call(method, params: params, timeout: clientTimeout(method: method, params: params))
    } catch let error as ControlClientError where error.exitCode == AsterCLIExitCode.unavailable {
      throw AgentHostMCPUnreachableError(message: error.message)
    }
  }

  /// 客户端等待上限：exec / wait / open 按 `timeout_ms` 推算，其余用默认值。
  static func clientTimeout(method: String, params: JSONValue) -> TimeInterval {
    let waiting: Set<String> = [
      AgentHostControlMethod.hostExec.rawValue, AgentHostControlMethod.hostWait.rawValue,
      AgentHostControlMethod.hostOpen.rawValue,
    ]
    guard waiting.contains(method) else { return ControlClient.defaultTimeout }
    let milliseconds = AgentHostValidation.clampedTimeout(params["timeout_ms"]?.intValue)
    return TimeInterval(milliseconds) / 1_000 + 15
  }

  /// 写一行响应；编码失败（理论上不会发生）时丢弃该行而不是写半包。
  private static func emit(_ response: JSONRPCResponse, encoder: JSONEncoder) {
    guard var data = try? encoder.encode(response) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
  }
}
