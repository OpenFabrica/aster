// `host.open|exec|wait|read|interrupt|close|terminals`：agent 在已保存主机上执行命令。
// 不走 IPC 写门禁（Allow Send Keys）：这组方法有自己的总开关与按主机批准，见 AgentHostService。
import AsterCore
import Foundation

extension AsterControlDispatcher {
  /// 处理 agent 远程执行方法。返回 nil 表示不是本组方法，交回原有分发。
  ///
  /// 会等待的方法（exec / wait / open / interrupt）占用每连接 4 个的等待名额；等待期间
  /// 请求只是挂起的 Task，同一连接上的其它请求照常处理。
  func handleAgentHostMethod(
    _ request: AsterControlRequest, client: any AsterControlClient
  ) async -> AsterControlResponse? {
    guard let method = AgentHostControlMethod(rawValue: request.method) else { return nil }
    do {
      guard let service = agentHostService ?? AgentHostService.shared else {
        throw AsterControlError(code: .internalError, message: "agent 主机服务未启动")
      }
      let result: JSONValue
      switch method {
      case .hostExec:
        let params = try Self.decodeAgentHostParams(HostExecParams.self, request)
        result = try JSONValue(encoding: try await withWaitSlot(client) { try await service.exec(params) })
      case .hostWait:
        let params = try Self.decodeAgentHostParams(HostWaitParams.self, request)
        result = try JSONValue(encoding: try await withWaitSlot(client) { try await service.wait(params) })
      case .hostOpen:
        let params = try Self.decodeAgentHostParams(HostOpenParams.self, request)
        result = try JSONValue(encoding: try await withWaitSlot(client) { try await service.open(params) })
      case .hostInterrupt:
        let params = try Self.decodeAgentHostParams(HostInterruptParams.self, request)
        result = try JSONValue(encoding: try await withWaitSlot(client) { try await service.interrupt(params) })
      case .hostRead:
        result = try JSONValue(encoding: try service.read(Self.decodeAgentHostParams(HostReadParams.self, request)))
      case .hostClose:
        try service.close(Self.decodeAgentHostParams(HostCloseParams.self, request))
        result = try JSONValue(encoding: AsterControlOKResult())
      case .hostTerminals:
        result = try JSONValue(encoding: service.terminals(Self.decodeAgentHostParams(HostTerminalsParams.self, request)))
      }
      return AsterControlResponse(id: request.id, result: result)
    } catch let error as AsterControlError {
      return AsterControlResponse(id: request.id, error: error)
    } catch is CancellationError {
      return AsterControlResponse(id: request.id, error: AsterControlError(code: .internalError, message: "连接已关闭"))
    } catch {
      return AsterControlResponse(id: request.id, error: AsterControlError(code: .internalError, message: "\(error)"))
    }
  }

  /// 解码并校验参数。
  private static func decodeAgentHostParams<T: Decodable & AsterControlValidatable>(
    _ type: T.Type, _ request: AsterControlRequest
  ) throws -> T {
    let params = try request.decodeParams(type)
    try params.validate()
    return params
  }

  /// 把 `$ASTER_PANE_ID` 解析成 Pane 显示 ID、Pane UUID 与其中 agent 的 provider / session ID。
  /// 解析不了（Pane 已关、不是 agent）就返回只有 Pane 的结果或 nil，不报错：身份扩展是尽力而为。
  func resolveAgentHostCallerPane(_ selector: String) -> AgentHostCallerPane? {
    guard let record = try? bridge.resolve(selector: selector) else { return nil }
    let info = bridge.agentInfo(record)
    return (
      record.paneID.description, record.runtime.id, info.flatMap { AgentProvider(rawValue: $0.agent) }, info?.sessionID
    )
  }
}
