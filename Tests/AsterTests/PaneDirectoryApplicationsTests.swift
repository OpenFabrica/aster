// Pane Open in 的应用集合、路径边界、真实图标来源及错误通道。
import AppKit
import Foundation
import Testing

@testable import Aster

private func paneApplicationDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("Aster Pane Applications \(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@MainActor
private func paneApplicationURL(_ identifier: String) -> URL {
  URL(fileURLWithPath: "/Applications/\(identifier).app")
}

@MainActor
private func invokePaneApplication(_ item: NSMenuItem) {
  // 直接调用动作也须重新校验路径，不能依赖菜单的 disabled 外观作为唯一保护。
  _ = item.target?.perform(item.action, with: item)
}

@Test("Pane Open in 只按固定顺序列出六种已安装应用并从应用路径加载图标")
@MainActor
func paneDirectoryApplicationsHaveFixedOrderAndIcons() throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var resolvedIdentifiers: [String] = []
  var iconURLs: [URL] = []
  let sourceIcon = NSImage(size: NSSize(width: 32, height: 32))
  let menu = PaneDirectoryApplications.menu(directory: directory.path, isRemote: false,
    resolver: {
      resolvedIdentifiers.append($0)
      return paneApplicationURL($0)
    }, iconProvider: {
      iconURLs.append($0)
      return sourceIcon
    }, opener: { _, _ in Issue.record("构造菜单不应打开应用") },
    completion: { _ in Issue.record("构造菜单不应触发完成回调") })
  let identifiers = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
    "dev.zed.Zed", "com.apple.finder", "com.apple.Terminal"]
  #expect(menu.items.map(\.title) == ["VS Code", "Cursor", "Xcode", "Zed", "Finder", "Terminal"])
  #expect(resolvedIdentifiers == identifiers)
  #expect(menu.items.map { $0.identifier?.rawValue } == identifiers.map(Optional.some))
  #expect(iconURLs == identifiers.map(paneApplicationURL))
  #expect(menu.items.allSatisfy { $0.isEnabled && $0.image?.size == NSSize(width: 16, height: 16) })
  #expect(menu.items.allSatisfy { $0.image !== sourceIcon })
  #expect(sourceIcon.size == NSSize(width: 32, height: 32))
  #expect(menu.items.allSatisfy { !$0.isSeparatorItem })
}

@Test("Pane Open in 跳过未安装应用，不加入终端标签或文件面板动作")
@MainActor
func paneDirectoryApplicationsSkipMissingApplications() throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let installed: Set<String> = ["dev.zed.Zed", "com.apple.Terminal"]
  let menu = PaneDirectoryApplications.menu(directory: directory.path, isRemote: false,
    resolver: { installed.contains($0) ? paneApplicationURL($0) : nil },
    iconProvider: { _ in NSImage(size: .zero) }, opener: { _, _ in }, completion: { _ in })
  #expect(menu.items.map(\.title) == ["Zed", "Terminal"])
  let empty = PaneDirectoryApplications.menu(directory: directory.path, isRemote: false,
    resolver: { _ in nil }, opener: { _, _ in }, completion: { _ in })
  #expect(empty.items.isEmpty)
}

@Test("Pane Open in 允许指向有效目录的软链")
@MainActor
func paneDirectoryApplicationsAcceptDirectorySymlinks() throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let link = directory.appendingPathComponent("linked-directory")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
  let menu = PaneDirectoryApplications.menu(directory: link.path, isRemote: false,
    resolver: { $0 == "com.apple.finder" ? paneApplicationURL($0) : nil },
    iconProvider: { _ in NSImage(size: .zero) }, opener: { _, _ in }, completion: { _ in })
  #expect(try #require(menu.items.first).isEnabled)
}

@Test("Pane Open in 拒绝缺失、相对、URI、非目录和远端目录")
@MainActor
func paneDirectoryApplicationsDisableUnavailableDirectories() throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("regular-file")
  try Data().write(to: file)
  let cases: [(String?, Bool)] = [
    (nil, false), ("", false), ("relative/path", false), ("~/project", false),
    ("ssh://host/project", false), ("file://" + directory.path, false),
    (directory.appendingPathComponent("missing").path, false), (file.path, false),
    (directory.path, true),
  ]
  for (path, remote) in cases {
    let menu = PaneDirectoryApplications.menu(directory: path, isRemote: remote,
      resolver: { $0 == "com.apple.finder" ? paneApplicationURL($0) : nil },
      iconProvider: { _ in NSImage(size: .zero) }, opener: { _, _ in }, completion: { _ in })
    let item = try #require(menu.items.first)
    #expect(item.isEnabled == false)
    #expect(item.toolTip?.isEmpty == false)
    #expect(menu.autoenablesItems == false)
  }
}

@Test("Pane Open in 保留带空格目录并用点击时重新解析的应用路径打开")
@MainActor
func paneDirectoryApplicationsOpenExactDirectoryAndCurrentApplication() async throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let movedApplication = URL(fileURLWithPath: "/Applications/Editors/Code.app")
  var application = paneApplicationURL("com.microsoft.VSCode")
  var opened: [(URL, URL)] = []
  let result: Result<Void, Error> = await withCheckedContinuation { continuation in
    let menu = PaneDirectoryApplications.menu(directory: directory.path, isRemote: false,
      resolver: { $0 == "com.microsoft.VSCode" ? application : nil },
      iconProvider: { _ in NSImage(size: .zero) }, opener: { opened.append(($0, $1)) },
      completion: { continuation.resume(returning: $0) })
    application = movedApplication
    invokePaneApplication(menu.items[0])
  }
  try result.get()
  #expect(opened.count == 1)
  #expect(opened.first?.0 == directory.standardizedFileURL)
  #expect(opened.first?.1 == movedApplication)
}

@Test("Pane Open in 将打开失败原样交给完成回调")
@MainActor
func paneDirectoryApplicationsReportOpeningFailure() async throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let expected = NSError(domain: "PaneDirectoryApplicationsTests", code: 42)
  let result: Result<Void, Error> = await withCheckedContinuation { continuation in
    let menu = PaneDirectoryApplications.menu(directory: directory.path, isRemote: false,
      resolver: { $0 == "com.apple.Terminal" ? paneApplicationURL($0) : nil },
      iconProvider: { _ in NSImage(size: .zero) }, opener: { _, _ in throw expected },
      completion: { continuation.resume(returning: $0) })
    invokePaneApplication(menu.items[0])
  }
  guard case .failure(let error) = result else {
    Issue.record("打开失败必须返回 failure")
    return
  }
  #expect(error as NSError == expected)
}

@Test("Pane Open in 点击时阻止远端、已删除目录或已卸载应用", arguments: ["remote", "directory", "application"])
@MainActor
func paneDirectoryApplicationsRecheckAvailabilityOnAction(boundary: String) async throws {
  let directory = try paneApplicationDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  var installed = true
  var opened = false
  var menu: NSMenu?
  let result: Result<Void, Error> = await withCheckedContinuation { continuation in
    menu = PaneDirectoryApplications.menu(directory: directory.path, isRemote: boundary == "remote",
      resolver: { $0 == "com.apple.finder" && installed ? paneApplicationURL($0) : nil },
      iconProvider: { _ in NSImage(size: .zero) }, opener: { _, _ in opened = true },
      completion: { continuation.resume(returning: $0) })
    if boundary == "directory" {
      do { try FileManager.default.removeItem(at: directory) }
      catch { Issue.record("测试目录移除失败：\(error)") }
    } else if boundary == "application" {
      installed = false
    }
    if let item = menu?.items.first { invokePaneApplication(item) }
    else { continuation.resume(returning: .success(())) }
  }
  #expect(opened == false)
  if case .success = result { Issue.record("不可用目标必须返回 failure") }
}
