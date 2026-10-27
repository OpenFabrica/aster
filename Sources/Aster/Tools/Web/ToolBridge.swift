// 网页工具桥接：处理 `window.aster` 发来的请求——限流、解析、授权，再分派到各项能力。
// 只收主 frame 消息的 WebKit 代理在 `ToolBridgeMessageProxy.swift`。
import AppKit
import AsterCore
import Foundation

/// 桥接向外请求的能力；`WebToolViewController` 实现并转给 `ToolWebHost`，测试可以替换。
@MainActor
protocol ToolBridgeDelegate: AnyObject {
  /// 当前请求：`tool.input` 与 `files.read` 的输入文件都以它为准。
  var bridgeLaunchRequest: ToolLaunchRequest { get }
  /// 文件选择框、确认框挂靠的窗口。
  var bridgePresentationWindow: NSWindow? { get }
  /// 页面希望的内容高度（已夹到 120–800）。
  func bridge(_ bridge: ToolBridge, didRequestHeight height: CGFloat)
  /// 页面请求关闭工具。
  func bridgeDidRequestClose(_ bridge: ToolBridge)
  /// 预填到来源终端；失败返回原因。
  func bridge(_ bridge: ToolBridge, insertIntoTerminal text: String) -> String?
  /// 来源终端的选区。
  func bridgeTerminalSelection(_ bridge: ToolBridge) -> String?
}

/// 一个网页工具页面的桥接。所有成员在主线程使用；耗时操作在后台完成，
/// 桥接失效（工具关闭）后迟到的结果直接丢弃，不再回复页面、也不再回调代理。
@MainActor
final class ToolBridge {
  typealias ReplyHandler = @MainActor @Sendable (Any?, String?) -> Void

  /// `files.pick` 最多接受的扩展名个数。
  static let maximumPickExtensions = 32
  /// 路径、网址参数的字节上限。
  static let maximumPathBytes = 4_096
  /// 通知标题与正文的字符上限。
  static let maximumNotificationTitleLength = 256
  static let maximumNotificationBodyLength = 1_024

  let plugin: ToolPluginRuntimeInfo
  weak var delegate: ToolBridgeDelegate?
  /// 实际可用的权限：已授予、并且清单仍然声明的。新版本清单删掉的权限不再可用。
  let effectivePermissions: Set<ToolPermission>
  /// 实际可访问的域名：已授予、并且清单仍然声明的。
  let effectiveNetworkDomains: [String]
  private let services: any ToolBridgeServices
  private let storage: ToolPluginStorage
  /// 只有可用 network 权限时才创建；失效时取消全部请求。
  private let session: URLSession?
  private let clock: () -> TimeInterval
  /// 限流器用 AsterCore 的 `ToolBridgeRateLimiter`（每秒 `maximumCallsPerSecond` 次）。
  private var rateLimiter = ToolBridgeRateLimiter(limit: ToolBridgeProtocol.maximumCallsPerSecond)
  /// 本会话经 `files.pick` 选中的文件（规范化路径）。
  private var pickedFiles: Set<String> = []
  private var pendingTasks: [UUID: Task<Void, Never>] = [:]
  /// 同一时间只弹一个文件选择框或确认框。
  private var isPresentingPanel = false
  private(set) var isInvalidated = false

  /// `sessionConfiguration` 只给测试替换网络层；`clock` 是单调时钟，用于限流。
  init(
    plugin: ToolPluginRuntimeInfo,
    services: any ToolBridgeServices,
    sessionConfiguration: URLSessionConfiguration? = nil,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.plugin = plugin
    self.services = services
    self.clock = clock
    effectivePermissions = plugin.grantedPermissions.intersection(plugin.manifest.permissions)
    effectiveNetworkDomains = plugin.grantedNetworkDomains.filter { plugin.manifest.network.contains($0) }
    storage = ToolPluginStorage.shared(for: plugin.dataDirectory)
    session =
      effectivePermissions.contains(.network)
      ? ToolNetworkFetcher.makeSession(base: sessionConfiguration ?? .ephemeral) : nil
  }

  deinit {
    session?.invalidateAndCancel()
  }

  /// 处理一条消息。先限流再解析：畸形消息也计数，刷大消息不会反复占用主线程做 JSON 解析。
  func handle(body: Any, reply: @escaping ReplyHandler) {
    guard !isInvalidated else {
      reply(nil, ToolBridgeError.unavailable(L("工具已关闭")).replyString)
      return
    }
    let request: ToolBridgeRequest
    do {
      guard rateLimiter.allow(now: clock()) else { throw ToolBridgeError.rateLimited }
      request = try ToolBridgeValidator.parse(body)
      try ToolBridgeValidator.authorize(request, granted: effectivePermissions)
    } catch {
      reply(nil, Self.bridgeError(error).replyString)
      return
    }
    let id = UUID()
    pendingTasks[id] = Task { [weak self] in
      guard let self else { return }
      let result: Result<JSONValue, ToolBridgeError>
      do {
        result = .success(try await self.perform(request))
      } catch {
        result = .failure(Self.bridgeError(error))
      }
      self.pendingTasks[id] = nil
      guard !self.isInvalidated else { return }
      switch result {
      case .success(let value): reply(value.foundationObject, nil)
      case .failure(let error): reply(nil, error.replyString)
      }
      // ui.close 先回复再请求关闭：关闭会让桥接失效，之后就回复不了了。
      if request.method == .close { self.delegate?.bridgeDidRequestClose(self) }
    }
  }

  /// 工具关闭：取消进行中的请求与网络任务，收起对话框；之后的消息一律回 unavailable。
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    for task in pendingTasks.values { task.cancel() }
    pendingTasks.removeAll()
    session?.invalidateAndCancel()
    services.dismissPresentedSheets()
    delegate = nil
  }

  /// `tool.input` 与 `enter` 事件共用的 `{code, input, context}`；`input` 与 Swift 的 `ToolInput` 编码一致。
  static func toolInputPayload(for request: ToolLaunchRequest) throws -> JSONValue {
    let input: JSONValue
    let context: JSONValue
    do {
      input = try JSONValue(encoding: request.input)
      context = try JSONValue(encoding: request.input.context)
    } catch {
      throw ToolBridgeError.failed(L("无法编码工具输入"))
    }
    return .object(["code": .string(request.entry.feature.code), "input": input, "context": context])
  }

  /// 任意错误统一成桥接错误；未知错误只带系统描述，不带插件数据。
  static func bridgeError(_ error: any Error) -> ToolBridgeError {
    if let error = error as? ToolBridgeError { return error }
    if error is CancellationError { return .unavailable(L("工具已关闭")) }
    return .failed(error.localizedDescription)
  }

  // MARK: - 分派

  /// 按方法执行；参数不合格、能力不可用都抛 `ToolBridgeError`。
  private func perform(_ request: ToolBridgeRequest) async throws -> JSONValue {
    let params = request.params
    switch request.method {
    case .toolInput:
      guard let launch = delegate?.bridgeLaunchRequest else { throw ToolBridgeError.unavailable(L("工具已关闭")) }
      return try Self.toolInputPayload(for: launch)
    case .setHeight:
      return try setHeight(params)
    case .close:
      return .null
    case .storageGet:
      return try await storage.value(forKey: try storageKey(params))
    case .storageSet:
      let key = try storageKey(params)
      guard let value = params["value"] else { throw ToolBridgeError.invalidParams("value") }
      try await storage.setValue(value, forKey: key)
      return .null
    case .storageRemove:
      try await storage.removeValue(forKey: try storageKey(params))
      return .null
    case .storageKeys:
      return .array(try await storage.keys().map(JSONValue.string))
    case .clipboardReadText:
      return try boundedText(services.readClipboardText())
    case .clipboardWriteText:
      services.writeClipboardText(
        try ToolBridgeParams.requiredString(params, "text", maximumBytes: ToolBridgeProtocol.maximumTextBytes))
      return .null
    case .terminalInsert:
      return try insertIntoTerminal(params)
    case .terminalSelection:
      return try boundedText(delegate?.bridgeTerminalSelection(self))
    case .filesPick:
      return try await pickFiles(params)
    case .filesRead:
      return try await readFile(params)
    case .netFetch:
      return try await fetch(params)
    case .notify:
      return try await notify(params)
    case .openURL:
      return try await openURL(params)
    }
  }

  /// `ui.setHeight`：取整后夹到清单允许的高度范围。
  private func setHeight(_ params: [String: JSONValue]) throws -> JSONValue {
    let requested = try ToolBridgeParams.number(params, "height").rounded()
    let range = ToolUIConfig.heightRange
    let height = min(max(requested, Double(range.lowerBound)), Double(range.upperBound))
    delegate?.bridge(self, didRequestHeight: CGFloat(height))
    return .null
  }

  /// 存储 key：非空，≤ 128 字节。
  private func storageKey(_ params: [String: JSONValue]) throws -> String {
    let key = try ToolBridgeParams.requiredString(
      params, "key", maximumBytes: ToolBridgeProtocol.maximumStorageKeyBytes)
    guard !key.isEmpty else { throw ToolBridgeError.invalidParams("key") }
    return key
  }

  /// 剪贴板、选区这类读出来的文本：没有时回 null，超过 1 MiB 拒绝。
  private func boundedText(_ text: String?) throws -> JSONValue {
    guard let text else { return .null }
    guard text.utf8.count <= ToolBridgeProtocol.maximumTextBytes else { throw ToolBridgeError.payloadTooLarge }
    return .string(text)
  }

  /// `terminal.insert`：交给来源终端预填（不回车），宿主返回原因即失败。
  private func insertIntoTerminal(_ params: [String: JSONValue]) throws -> JSONValue {
    let text = try ToolBridgeParams.requiredString(params, "text", maximumBytes: ToolBridgeProtocol.maximumTextBytes)
    guard let delegate else { throw ToolBridgeError.unavailable(L("工具已关闭")) }
    if let failure = delegate.bridge(self, insertIntoTerminal: text) { throw ToolBridgeError.unavailable(failure) }
    return .null
  }

  // MARK: - 文件

  /// `files.pick`：弹出原生文件选择框，选中的文件记入本会话允许列表，返回规范化路径。
  private func pickFiles(_ params: [String: JSONValue]) async throws -> JSONValue {
    let extensions = try ToolBridgeParams.stringArray(params, "extensions", maximumCount: Self.maximumPickExtensions)
      .map { raw in
        let ext = (raw.hasPrefix(".") ? String(raw.dropFirst()) : raw).lowercased()
        guard (1...16).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
          throw ToolBridgeError.invalidParams("extensions")
        }
        return ext
      }
    let multiple = try ToolBridgeParams.bool(params, "multiple", default: false)
    guard !isPresentingPanel else { throw ToolBridgeError.unavailable(L("已经有一个对话框在等待处理")) }
    isPresentingPanel = true
    defer { isPresentingPanel = false }
    let urls = await services.pickFiles(
      allowedExtensions: extensions, allowsMultiple: multiple, pluginName: plugin.manifest.name,
      window: delegate?.bridgePresentationWindow)
    let paths = urls.compactMap { ToolFileReader.normalizedPath($0.path) }
    pickedFiles.formUnion(paths)
    return .array(paths.map(JSONValue.string))
  }

  /// `files.read`：只认本会话选中过的文件与当前输入里的文件，后台读取。
  private func readFile(_ params: [String: JSONValue]) async throws -> JSONValue {
    let rawPath = try ToolBridgeParams.requiredString(params, "path", maximumBytes: Self.maximumPathBytes)
    let encodingName =
      try ToolBridgeValidator.string(params, "encoding", maximumBytes: 16, required: false)?.lowercased() ?? "utf8"
    guard let encoding = ToolFileReadEncoding(rawValue: encodingName == "utf-8" ? "utf8" : encodingName) else {
      throw ToolBridgeError.invalidParams("encoding")
    }
    // 允许列表按规范化路径比对：`/a/./b`、`/a//b` 与 `/a/b` 视为同一个文件，但不跟随符号链接改写路径。
    guard let path = ToolFileReader.normalizedPath(rawPath), isReadable(path) else {
      throw ToolBridgeError.invalidParams(L("只能读取用户选择或传入的文件"))
    }
    let text = try await Task.detached(priority: .userInitiated) {
      try ToolFileReader.read(path: path, encoding: encoding, maximumBytes: ToolBridgeProtocol.maximumFileReadBytes)
    }.value
    return .string(text)
  }

  /// 路径是否在本会话允许列表里：`files.pick` 选中过的，或当前输入里的文件。
  private func isReadable(_ path: String) -> Bool {
    if pickedFiles.contains(path) { return true }
    let inputFiles = delegate?.bridgeLaunchRequest.input.files ?? []
    return inputFiles.contains { ToolFileReader.normalizedPath($0) == path }
  }

  // MARK: - 网络、通知与外部链接

  /// `net.fetch`：校验后在后台代发；页面关闭时会话失效，请求随之取消。
  private func fetch(_ params: [String: JSONValue]) async throws -> JSONValue {
    guard let session else { throw ToolBridgeError.permissionDenied(.network) }
    let domains = effectiveNetworkDomains
    let request = try ToolFetchPolicy.validate(params, allowedDomains: domains)
    let response = try await Task.detached(priority: .userInitiated) {
      try await ToolNetworkFetcher.perform(request, session: session, allowedDomains: domains)
    }.value
    return response.jsonValue
  }

  /// `notify`：标题必填，标题与正文有字符上限；控制字符换成空格（正文保留换行），不把它们写进系统界面。
  private func notify(_ params: [String: JSONValue]) async throws -> JSONValue {
    let rawTitle = try ToolBridgeParams.requiredString(
      params, "title", maximumBytes: 4 * Self.maximumNotificationTitleLength)
    let rawBody = try ToolBridgeValidator.string(
      params, "body", maximumBytes: 4 * Self.maximumNotificationBodyLength, required: false)
    let title = Self.sanitizedNotificationText(rawTitle, keepsNewlines: false)
    let body = rawBody.map { Self.sanitizedNotificationText($0, keepsNewlines: true) }
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolBridgeError.invalidParams("title") }
    guard title.count <= Self.maximumNotificationTitleLength,
      (body?.count ?? 0) <= Self.maximumNotificationBodyLength
    else { throw ToolBridgeError.payloadTooLarge }
    try await services.post(
      ToolNotificationContent(
        title: title, body: body?.isEmpty == true ? nil : body, pluginID: plugin.manifest.id,
        pluginName: plugin.manifest.name))
    return .null
  }

  /// 把控制字符换成空格；`keepsNewlines` 时保留 `\n`。
  static func sanitizedNotificationText(_ text: String, keepsNewlines: Bool) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { scalar in
          if keepsNewlines, scalar == "\n" { return scalar }
          return CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }))
  }

  /// `shell.openURL`：只允许 http(s)，先弹确认；返回用户是否同意。
  private func openURL(_ params: [String: JSONValue]) async throws -> JSONValue {
    let text = try ToolBridgeParams.requiredString(params, "url", maximumBytes: Self.maximumPathBytes)
    guard let url = WebPaneURLPolicy.allowedURL(from: text) else {
      throw ToolBridgeError.invalidParams(L("只允许 http(s) 地址"))
    }
    guard !isPresentingPanel else { throw ToolBridgeError.unavailable(L("已经有一个对话框在等待处理")) }
    isPresentingPanel = true
    defer { isPresentingPanel = false }
    let approved = await services.confirmOpening(
      url, pluginName: plugin.manifest.name, window: delegate?.bridgePresentationWindow)
    guard approved, !isInvalidated else { return .bool(false) }
    services.openInBrowser(url)
    return .bool(true)
  }
}
