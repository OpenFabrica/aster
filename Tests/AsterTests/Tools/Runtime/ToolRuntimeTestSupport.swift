// 工具运行时测试的共用设施：临时沙箱目录、插件清单写入、假确认器、假的删除操作与假容器。
import AppKit
import AsterCore
import Foundation
import os

@testable import Aster

/// 记录确认请求并按 `answer` 回答，不出真界面。
@MainActor
final class FakeToolApprover: ToolInstallApproving {
  var answer = true
  private(set) var prompts: [ToolInstallPrompt] = []

  func requestApproval(for prompt: ToolInstallPrompt, window: NSWindow?) async -> Bool {
    prompts.append(prompt)
    return answer
  }
}

/// 代替「移到废纸篓」：直接删除并记下路径，测试不往用户废纸篓里塞东西。
final class ToolTrashRecorder: Sendable {
  private let urls = OSAllocatedUnfairLock<[URL]>(initialState: [])

  var removed: [URL] { urls.withLock { $0 } }

  func remove(_ url: URL) throws {
    try FileManager.default.removeItem(at: url)
    urls.withLock { $0.append(url) }
  }
}

/// 记下被删除的 WebKit 数据存储标识；`failuresRemaining` 次之内像 WebKit 一样报「仍在使用」。
@MainActor
final class ToolWebsiteDataRecorder {
  struct InUse: Error {}

  private(set) var removed: [UUID] = []
  private(set) var attempts = 0
  /// 还要失败几次；`Int.max` 表示一直失败。
  var failuresRemaining = 0

  func remove(_ identifier: UUID) throws {
    attempts += 1
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw InUse()
    }
    removed.append(identifier)
  }
}

/// 一个测试用的临时目录：`AppSupport/`、`Resources/tools-builtin/` 与放待安装插件的 `External/`。
/// realpath 规范路径：`ScriptToolProtocol.resolveExecutable` 用 realpath，临时目录的 `/var` 会展开成 `/private/var`，
/// 而 `resolvingSymlinksInPath()` 会把它写回 `/var`；断言可执行文件路径时两边要用同一种写法。
func canonicalToolPath(_ url: URL) -> String {
  guard let resolved = realpath(url.path, nil) else { return url.path }
  defer { free(resolved) }
  return String(cString: resolved)
}

@MainActor
final class ToolRuntimeSandbox {
  let root: URL
  let approver = FakeToolApprover()
  let trash = ToolTrashRecorder()
  let websiteData = ToolWebsiteDataRecorder()
  let secureKeys = InMemoryToolSecureStorageKeyStore()

  init() throws {
    // 与扫描器用同一种解析（`resolvingSymlinksInPath()`，`/private/var` 会写回 `/var`）：扫描结果里的目录
    // 都是这样解析过的路径，断言要用同一种写法。可执行文件路径另用 `canonicalToolPath`。
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("aster-tools-runtime-\(UUID().uuidString)", isDirectory: true)
    for directory in [appSupport, builtinDirectory, external] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  var appSupport: URL { root.appendingPathComponent("AppSupport", isDirectory: true) }
  var resources: URL { root.appendingPathComponent("Resources", isDirectory: true) }
  var builtinDirectory: URL { resources.appendingPathComponent("tools-builtin", isDirectory: true) }
  var pluginsDirectory: URL { appSupport.appendingPathComponent("Plugins", isDirectory: true) }
  var external: URL { root.appendingPathComponent("External", isDirectory: true) }
  var stateFile: URL { appSupport.appendingPathComponent(ToolStateFile.fileName) }

  /// 用沙箱目录、假确认器与假删除建一个工具中心；不监听文件系统，使用记录 10 ms 去抖。
  /// 内置清单翻译默认原样返回，断言不受测试宿主界面语言影响。
  func makeCenter(translate: @escaping (String) -> String = { $0 }) -> ToolCenter {
    let trash = trash
    let websiteData = websiteData
    return ToolCenter(
      environment: ToolCenterEnvironment(
        applicationSupportDirectory: appSupport, resourcesDirectory: resources, approver: approver,
        moveToTrash: { url in try trash.remove(url) },
        removeWebsiteData: { identifier in try websiteData.remove(identifier) },
        watchesFileSystem: false, usageSaveDelay: .milliseconds(10),
        terminalStyle: { ToolTerminalStyle.current() }, translateBuiltinText: translate,
        secureKeyStore: secureKeys))
  }

  /// 删除整个沙箱。
  func cleanup() {
    do {
      try FileManager.default.removeItem(at: root)
    } catch {
      // 临时目录删不掉不影响断言，系统会定期清理。
    }
  }
}

/// 一个跑 `/bin/echo hi` 的 text 脚本功能。
func echoFeature(code: String = "run", title: String = "Echo", arguments: [String] = ["hi"]) -> [String: Any] {
  [
    "code": code, "title": title, "keywords": [code],
    "action": ["type": "script", "command": ["/bin/echo"] + arguments, "output": "text"],
  ]
}

/// 一个网页功能。
func uiFeature(code: String = "open", title: String = "Open") -> [String: Any] {
  ["code": code, "title": title, "keywords": [code], "action": ["type": "ui"]]
}

/// 在 `directory` 写一个插件：清单加 `index.html`，再按需写额外文件。返回插件目录。
@discardableResult
func writeToolPlugin(
  at directory: URL,
  id: String,
  name: String = "Test Plugin",
  version: String = "1.0.0",
  permissions: [String] = ["exec"],
  features: [[String: Any]] = [echoFeature()],
  ui: [String: Any]? = nil,
  files: [String: String] = [:]
) throws -> URL {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  var manifest: [String: Any] = [
    "schemaVersion": 1, "id": id, "name": name, "version": version, "permissions": permissions,
    "features": features,
  ]
  if let ui { manifest["ui"] = ui }
  let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: directory.appendingPathComponent(ToolManifest.fileName))
  try Data("<!doctype html><title>t</title>".utf8).write(to: directory.appendingPathComponent("index.html"))
  for (path, content) in files {
    let url = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }
  return directory
}

/// 把文件设成可执行。
func makeExecutable(_ url: URL) throws {
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// 在主线程上轮询直到条件成立或超时；返回最终结果。
@MainActor
func waitForToolCondition(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() { return true }
    do {
      try await Task.sleep(for: .milliseconds(20))
    } catch {
      break
    }
  }
  return condition()
}

/// 记录工具会话向容器的请求。
@MainActor
final class FakeToolSessionHost: ToolSessionHost {
  private(set) var closeRequests = 0
  private(set) var heights: [CGFloat] = []
  private(set) var notices: [(text: String, isError: Bool)] = []
  private(set) var inserted: [String] = []
  private(set) var terminalRuns: [(command: [String], workingDirectory: String?, environment: [String: String])] = []
  private(set) var openInPaneRequests = 0
  var insertSucceeds = true

  func toolSessionDidRequestClose(_ session: ToolSessionViewController) { closeRequests += 1 }

  func toolSession(_ session: ToolSessionViewController, didRequestHeight height: CGFloat) { heights.append(height) }

  func toolSession(_ session: ToolSessionViewController, showNotice text: String, isError: Bool) {
    notices.append((text, isError))
  }

  func toolSession(_ session: ToolSessionViewController, insertIntoTerminal text: String) -> Bool {
    inserted.append(text)
    return insertSucceeds
  }

  func toolSessionOpenInPane(_ session: ToolSessionViewController) { openInPaneRequests += 1 }

  func toolSession(
    _ session: ToolSessionViewController,
    runInTerminal command: [String],
    workingDirectory: String?,
    environment: [String: String]
  ) {
    terminalRuns.append((command, workingDirectory, environment))
  }

  var toolSessionWindow: NSWindow? { nil }
}
