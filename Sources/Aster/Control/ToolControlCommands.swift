// `tool.list` / `tool.run` 控制协议方法：让 `aster mcp` 列出插件命令，并无界面地运行脚本与内置转换。
// 协议类型在 AsterCore/Tools/ToolControlProtocol.swift；规则见 docs/developer/tools-and-plugins.md「控制协议」。
import AsterCore
import Foundation

/// 控制协议看到的一条功能及其插件当前状态（含停用与待确认）。
struct ToolControlEntry: Equatable, Sendable {
  let entry: ToolCatalogEntry
  let status: ToolPluginStatus
}

/// `tool.*` 依赖的工具中心能力。生产是 `ToolCenter.shared`，测试注入替身，不碰真实插件目录。
@MainActor
protocol ToolControlProviding: AnyObject {
  /// 全部功能（含停用插件）及插件状态，按目录顺序。
  func controlEntries() -> [ToolControlEntry]
  /// 运行前的摘要复核；插件已不存在时为 nil。
  func prepareToRun(pluginID: String) async -> ToolPluginStatus?
  /// 运行脚本需要的目录与权限；插件不可运行时为 nil。
  func runtimeInfo(pluginID: String) -> ToolPluginRuntimeInfo?
  /// 组装交给脚本的环境（界面语言、外观、工作目录）。
  func makeContext(workingDirectory: String?, isRemote: Bool) -> ToolContext
}

extension ToolCenter: ToolControlProviding {}

extension AsterControlDispatcher {
  /// 能产出 `BuiltinTextTools.inlineResult` 的内置处理器；其余（json / ports / uuid / stickies）是原生界面工具。
  static let headlessBuiltinHandlers: Set<ToolBuiltinHandler> = [.timestamp, .base64, .url, .hash]

  /// 处理插件命令方法。返回 nil 表示不是本组方法，交回原有分发。
  ///
  /// 不走 IPC 写门禁（Allow Send Keys）：那个开关管的是「往用户的 Pane 里打字」，而插件是用户已经安装并
  /// 确认过权限的程序，运行它不触碰任何 Pane。需要确认的插件直接报错，绝不从 IPC 请求里弹授权对话框——
  /// 后台 agent 触发的弹窗容易被用户顺手点掉，授权必须由用户在 Aster 里主动打开工具完成。
  func handleToolMethod(_ request: AsterControlRequest, client: any AsterControlClient) async -> AsterControlResponse? {
    guard let method = ToolControlMethod(rawValue: request.method) else { return nil }
    let provider = toolControlProvider ?? ToolCenter.shared
    do {
      let result: JSONValue
      switch method {
      case .toolList:
        let params = try Self.decodeToolParams(ToolListParams.self, request)
        result = try JSONValue(encoding: Self.listTools(provider.controlEntries(), query: params.query))
      case .toolRun:
        let params = try Self.decodeToolParams(ToolRunParams.self, request)
        result = try JSONValue(encoding: try await runTool(params, provider: provider, client: client))
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

  // MARK: - tool.list

  /// 投影成协议条目；`query` 非空时按启动器的模糊匹配筛选排序。不传使用记录、也不记使用次数：
  /// agent 的查询不该影响用户启动器的排序，结果也不该随用户习惯变化。
  static func listTools(_ items: [ToolControlEntry], query: String?) -> ToolListResult {
    let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return ToolListResult(tools: items.map(toolCommandInfo)) }
    let statuses = Dictionary(items.map { ($0.entry.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    let matches = ToolMatcher.search(
      trimmed, entries: items.map(\.entry), usage: ToolUsageStats(), now: Date(), limit: items.count)
    return ToolListResult(
      tools: matches.compactMap { match in
        statuses[match.entry.id].map { toolCommandInfo(ToolControlEntry(entry: match.entry, status: $0)) }
      })
  }

  /// 一条功能的协议形状：种类、输出方式、状态与可运行性。
  static func toolCommandInfo(_ item: ToolControlEntry) -> ToolCommandInfo {
    let shape = toolShape(item.entry)
    let reason = shape.blocker ?? statusBlocker(item.status)
    let feature = item.entry.feature
    return ToolCommandInfo(
      id: item.entry.id, pluginID: item.entry.pluginID, pluginName: item.entry.pluginName, title: feature.title,
      subtitle: feature.subtitle, keywords: feature.keywords, kind: shape.kind, output: shape.output,
      status: commandStatus(item.status), runnable: reason == nil, unavailableReason: reason)
  }

  /// 动作种类、脚本输出方式，以及动作本身决定的「不能无界面运行」原因（与插件状态无关）。
  static func toolShape(_ entry: ToolCatalogEntry) -> (kind: ToolCommandKind, output: String?, blocker: String?) {
    switch entry.feature.action {
    case .ui:
      return (.ui, nil, "Opens a web interface; use it inside Aster.")
    case .script(let action):
      let blocker: String? =
        action.output == .terminal ? "Runs in a new terminal tab; use it inside Aster." : nil
      return (.script, action.output.rawValue, blocker)
    case .builtin(let action):
      let blocker: String? =
        headlessBuiltinHandlers.contains(action.handler) ? nil : "Native Aster interface tool; use it inside Aster."
      return (.builtin, nil, blocker)
    }
  }

  /// 插件状态决定的不可运行原因；ready 为 nil。
  static func statusBlocker(_ status: ToolPluginStatus) -> String? {
    switch status {
    case .ready: nil
    case .disabled: "Plugin is disabled; enable it in Aster Settings > Tools."
    case .needsApproval: "Plugin needs approval; open this tool once in Aster to review its permissions."
    }
  }

  /// 插件状态到协议状态。
  static func commandStatus(_ status: ToolPluginStatus) -> ToolCommandStatus {
    switch status {
    case .ready: .ready
    case .disabled: .disabled
    case .needsApproval: .needsApproval
    }
  }

  // MARK: - tool.run

  /// 按 id 找到功能并运行。不调用 `recordUse`：agent 调用不该影响启动器排序。
  private func runTool(
    _ params: ToolRunParams, provider: any ToolControlProviding, client: any AsterControlClient
  ) async throws -> ToolRunResult {
    let start = ContinuousClock.now
    guard let item = provider.controlEntries().first(where: { $0.entry.id == params.id }) else {
      throw AsterControlError(code: .notFound, message: "No plugin tool with id \(params.id)")
    }
    if let blocker = Self.toolShape(item.entry).blocker {
      throw AsterControlError(code: .invalidParams, message: "Tool \(params.id) cannot run headlessly: \(blocker)")
    }
    try Self.requireReady(item.status, id: params.id)
    switch item.entry.feature.action {
    case .builtin(let action):
      guard
        let text = BuiltinTextTools.inlineResult(
          action.handler, input: params.input ?? "", now: Date(), timeZone: .current)
      else {
        throw AsterControlError(
          code: .invalidParams, message: "Tool \(params.id) cannot process this input; pass input it understands")
      }
      return Self.textResult(id: params.id, text: text, start: start)
    case .script(let action):
      // 脚本最长可跑 60 s，占一个等待名额；等待期间同一连接上的其它请求照常处理。
      return try await withWaitSlot(client) {
        try await self.runScript(action, item: item.entry, params: params, provider: provider, start: start)
      }
    case .ui:
      throw AsterControlError(code: .invalidParams, message: "Tool \(params.id) cannot run headlessly")
    }
  }

  /// 运行脚本功能：先复核摘要（文件被改过就拒绝），再在后台组装并运行，按输出方式整理结果。
  private func runScript(
    _ action: ToolScriptAction, item: ToolCatalogEntry, params: ToolRunParams, provider: any ToolControlProviding,
    start: ContinuousClock.Instant
  ) async throws -> ToolRunResult {
    guard let status = await provider.prepareToRun(pluginID: item.pluginID) else {
      throw AsterControlError(code: .notFound, message: "Plugin \(item.pluginID) is no longer installed")
    }
    try Self.requireReady(status, id: params.id)
    guard let plugin = provider.runtimeInfo(pluginID: item.pluginID) else {
      throw AsterControlError(code: .internalError, message: "Plugin \(item.pluginID) is not available to run")
    }
    let input = ToolInput(
      text: params.input, source: params.input == nil ? .none : .typed,
      context: provider.makeContext(workingDirectory: params.cwd, isRemote: false))
    let output: ScriptToolOutput
    let items: [ToolListItem]?
    do {
      output = try await Self.executeToolScript(action: action, code: item.feature.code, plugin: plugin, input: input)
      items = action.output == .list ? try ScriptToolProtocol.parseList(output.stdout) : nil
    } catch let error as ScriptToolError {
      throw try Self.controlError(error, id: params.id)
    }
    switch action.output {
    case .list:
      return ToolRunResult(id: params.id, output: action.output.rawValue, items: items, durationMs: Self.elapsed(start))
    case .text:
      return Self.textResult(id: params.id, text: ScriptToolProtocol.decodeText(output.stdout), start: start)
    case .none, .terminal:
      return ToolRunResult(id: params.id, output: action.output.rawValue, durationMs: Self.elapsed(start))
    }
  }

  /// 后台组装并运行：`makeInvocation` 会解析可执行文件、建数据目录，必须离开主线程。
  @concurrent
  private nonisolated static func executeToolScript(
    action: ToolScriptAction, code: String, plugin: ToolPluginRuntimeInfo, input: ToolInput
  ) async throws -> ScriptToolOutput {
    let invocation = try ScriptToolRunner.makeInvocation(
      action: action, code: code, plugin: plugin, input: input, query: input.text)
    return try await ScriptToolRunner.run(invocation)
  }

  /// 状态不是 ready 时抛错，message 告诉 agent 用户该做什么。
  private static func requireReady(_ status: ToolPluginStatus, id: String) throws {
    guard let blocker = statusBlocker(status) else { return }
    throw AsterControlError(code: .invalidParams, message: "Tool \(id) cannot run: \(blocker)")
  }

  /// 脚本失败转控制错误；取消（连接关闭）交回统一的取消处理。
  private static func controlError(_ error: ScriptToolError, id: String) throws -> AsterControlError {
    switch error {
    case .cancelled:
      throw CancellationError()
    case .timedOut:
      return AsterControlError(code: .timeout, message: "Tool \(id) failed: \(error.localizedMessage)")
    default:
      return AsterControlError(code: .internalError, message: "Tool \(id) failed: \(error.localizedMessage)")
    }
  }

  /// text 结果：超过上限按字符边界截断并标记。
  private static func textResult(id: String, text: String, start: ContinuousClock.Instant) -> ToolRunResult {
    let (clipped, truncated) = truncatedToolText(text, maximumUTF8Bytes: ToolControlLimits.maximumOutputBytes)
    return ToolRunResult(id: id, output: "text", text: clipped, truncated: truncated, durationMs: elapsed(start))
  }

  /// 按 UTF-8 字节上限截断，退到字符边界，不切开多字节字符或组合字符。
  static func truncatedToolText(_ text: String, maximumUTF8Bytes: Int) -> (text: String, truncated: Bool) {
    guard text.utf8.count > maximumUTF8Bytes else { return (text, false) }
    var end = text.utf8.index(text.utf8.startIndex, offsetBy: maximumUTF8Bytes)
    while end > text.startIndex, end.samePosition(in: text) == nil {
      end = text.utf8.index(before: end)
    }
    return (String(text[..<end]), true)
  }

  /// 从 `start` 到现在的毫秒数。
  private static func elapsed(_ start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start) / .milliseconds(1))
  }

  /// 解码并校验参数。
  private static func decodeToolParams<T: Decodable & AsterControlValidatable>(
    _ type: T.Type, _ request: AsterControlRequest
  ) throws -> T {
    let params = try request.decodeParams(type)
    try params.validate()
    return params
  }
}
