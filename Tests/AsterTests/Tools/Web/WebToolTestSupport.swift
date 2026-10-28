// 网页工具测试共用：临时插件目录、插件与请求构造、假系统能力、假桥接代理与桥接调用封装。
import AppKit
import Foundation

@testable import Aster
@testable import AsterCore

/// 在临时目录里建一个插件目录并写入文件；返回解析过符号链接的目录（与运行时约定一致）。
func makeTemporaryPluginDirectory(files: [String: String] = [:]) throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-web-tool-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  for (path, content) in files {
    let url = root.appendingPathComponent(path, isDirectory: false)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }
  return root.resolvingSymlinksInPath()
}

/// 构造网页工具插件的运行信息。`granted` 缺省等于声明的权限，`grantedDomains` 缺省等于声明的域名。
func makeWebToolPlugin(
  id: String = "com.example.webtest",
  directory: URL,
  permissions: [ToolPermission] = [],
  granted: Set<ToolPermission>? = nil,
  network: [String] = [],
  grantedDomains: [String]? = nil,
  main: String = "index.html",
  source: ToolPluginSource = .development
) -> ToolPluginRuntimeInfo {
  let manifest = ToolManifest(
    id: id, name: "网页测试", version: "1.0.0", ui: ToolUIConfig(main: main, height: 300),
    permissions: permissions, network: network,
    features: [ToolFeature(code: "main", title: "Main", keywords: ["main"], action: .ui)])
  return ToolPluginRuntimeInfo(
    manifest: manifest, source: source, directory: directory,
    dataDirectory: directory.appendingPathComponent("data", isDirectory: true),
    grantedPermissions: granted ?? Set(permissions), grantedNetworkDomains: grantedDomains ?? network)
}

/// 构造打开网页工具的请求。
func makeWebToolRequest(
  pluginID: String = "com.example.webtest",
  text: String? = nil,
  files: [String] = []
) -> ToolLaunchRequest {
  let feature = ToolFeature(code: "main", title: "Main", keywords: ["main"], action: .ui)
  let entry = ToolCatalogEntry(
    pluginID: pluginID, pluginName: "网页测试", pluginVersion: "1.0.0", source: .development, feature: feature,
    hasUI: true)
  let input = ToolInput(
    text: text, files: files, source: text == nil ? .none : .typed,
    context: ToolContext(locale: "zh-Hans", appearance: "light"))
  return ToolLaunchRequest(entry: entry, input: input, origin: nil)
}

/// 不碰真实系统界面的系统能力：记录调用，按预设返回。
@MainActor
final class FakeToolBridgeServices: ToolBridgeServices {
  var clipboard: String?
  /// 最近一次写剪贴板是否标了机密。
  private(set) var clipboardConcealed = false
  var pickResult: [URL] = []
  var confirmResult = false
  private(set) var pickRequests: [(extensions: [String], multiple: Bool)] = []
  private(set) var confirmedURLs: [URL] = []
  private(set) var openedURLs: [URL] = []
  private(set) var notifications: [ToolNotificationContent] = []
  private(set) var dismissCount = 0

  func readClipboardText() -> String? { clipboard }
  func writeClipboardText(_ text: String, concealed: Bool) {
    clipboard = text
    clipboardConcealed = concealed
  }

  func pickFiles(allowedExtensions: [String], allowsMultiple: Bool, pluginName: String, window: NSWindow?) async
    -> [URL]
  {
    pickRequests.append((allowedExtensions, allowsMultiple))
    return pickResult
  }

  func confirmOpening(_ url: URL, pluginName: String, window: NSWindow?) async -> Bool {
    confirmedURLs.append(url)
    return confirmResult
  }

  func openInBrowser(_ url: URL) { openedURLs.append(url) }
  func post(_ notification: ToolNotificationContent) async throws { notifications.append(notification) }
  func dismissPresentedSheets() { dismissCount += 1 }
}

/// 假桥接代理：记录高度、关闭与终端预填。
@MainActor
final class FakeToolBridgeDelegate: ToolBridgeDelegate {
  var bridgeLaunchRequest: ToolLaunchRequest
  var bridgePresentationWindow: NSWindow? { nil }
  var insertFailure: String?
  var selection: String?
  private(set) var heights: [CGFloat] = []
  private(set) var closeCount = 0
  private(set) var insertedTexts: [String] = []

  init(request: ToolLaunchRequest) {
    bridgeLaunchRequest = request
  }

  func bridge(_ bridge: ToolBridge, didRequestHeight height: CGFloat) { heights.append(height) }
  func bridgeDidRequestClose(_ bridge: ToolBridge) { closeCount += 1 }

  func bridge(_ bridge: ToolBridge, insertIntoTerminal text: String) -> String? {
    insertedTexts.append(text)
    return insertFailure
  }

  func bridgeTerminalSelection(_ bridge: ToolBridge) -> String? { selection }
}

/// 桥接回复的可跨隔离形式：结果转成 JSON 文本，错误保留原字符串。
struct BridgeReply: Sendable {
  let json: String?
  let error: String?

  init(value: Any?, error: String?) {
    self.error = error
    if let value,
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    {
      json = String(decoding: data, as: UTF8.self)
    } else {
      json = nil
    }
  }

  /// 错误字符串里的 code（冒号前的部分）。
  var errorCode: String? { error.flatMap { $0.split(separator: ":").first.map(String.init) } }
}

/// 发一条桥接请求并等待回复。
@MainActor
func callBridge(_ bridge: ToolBridge, _ method: String, _ params: [String: Any] = [:]) async -> BridgeReply {
  await withCheckedContinuation { continuation in
    bridge.handle(body: ["v": 1, "method": method, "params": params]) { value, error in
      continuation.resume(returning: BridgeReply(value: value, error: error))
    }
  }
}

/// 可手动拨动的单调时钟，测试限流用。
@MainActor
final class ManualClock {
  var now: TimeInterval = 1_000
}
