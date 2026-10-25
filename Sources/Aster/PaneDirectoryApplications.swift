// Pane 当前目录的本机应用菜单，与 Shell 菜单中的终端/文件面板动作分开。
import AppKit

@MainActor
enum PaneDirectoryApplications {
  typealias Resolver = @MainActor (String) -> URL?
  typealias IconProvider = @MainActor (URL) -> NSImage
  typealias Opener = @MainActor (URL, URL) async throws -> Void
  typealias Completion = @MainActor (Result<Void, Error>) -> Void

  /// 只列出已安装的 VS Code、Cursor、Xcode、Zed、Finder、Terminal，保持此顺序。
  /// isRemote 必须来自 Pane 的传输状态：远端绝对路径可能也存在于本机，不能凭路径
  /// 猜测是否可打开。目录无效时保留已安装应用但禁用；点击时再次校验目录与安装态。
  /// 每次点击的成功或错误均交给 completion，由宿主呈现错误，不隐式弹出窗口。
  static func menu(
    directory: String?,
    isRemote: Bool,
    resolver: @escaping Resolver = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
    iconProvider: @escaping IconProvider = { NSWorkspace.shared.icon(forFile: $0.path) },
    opener: @escaping Opener = openDirectory,
    completion: @escaping Completion
  ) -> NSMenu {
    var applications = WorkspaceEditorLocator.detect(lookup: resolver)
    for (name, identifier) in [("Finder", "com.apple.finder"), ("Terminal", "com.apple.Terminal")] {
      if let url = resolver(identifier), url.isFileURL {
        applications.append(.init(name: name, bundleIdentifier: identifier, appURL: url))
      }
    }
    let availability = Result { try localDirectory(directory, isRemote: isRemote) }
    let menu = NSMenu(title: "Open in")
    menu.autoenablesItems = false
    for application in applications where application.appURL.isFileURL {
      let item = ActionMenuItem(title: application.name) {
        Task { @MainActor in
          do {
            let target = try localDirectory(directory, isRemote: isRemote)
            guard let currentApplication = resolver(application.bundleIdentifier), currentApplication.isFileURL else {
              throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: application.appURL.path])
            }
            try await opener(target, currentApplication)
            completion(.success(()))
          } catch {
            completion(.failure(error))
          }
        }
      }
      item.identifier = NSUserInterfaceItemIdentifier(application.bundleIdentifier)
      let sourceIcon = iconProvider(application.appURL)
      if let icon = sourceIcon.copy() as? NSImage {
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
      } else {
        item.image = sourceIcon
      }
      switch availability {
      case .success:
        item.isEnabled = true
      case .failure(let error):
        item.isEnabled = false
        item.toolTip = error.localizedDescription
      }
      menu.addItem(item)
    }
    return menu
  }

  private static func localDirectory(_ path: String?, isRemote: Bool) throws -> URL {
    guard !isRemote else { throw CocoaError(.fileReadUnsupportedScheme) }
    guard let path, path.hasPrefix("/"), !path.contains("\0") else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    // Shell 的逻辑 PWD 可以指向目录软链（如 /tmp）；跟随检查但保留原始打开路径。
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    guard isDirectory.boolValue else {
      throw POSIXError(.ENOTDIR)
    }
    return url
  }

  /// 显式指定已解析的应用打开目录，Finder 也走同一条带错误返回的 NSWorkspace API。
  private static func openDirectory(_ directory: URL, application: URL) async throws {
    _ = try await NSWorkspace.shared.open(
      [directory], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
  }
}
