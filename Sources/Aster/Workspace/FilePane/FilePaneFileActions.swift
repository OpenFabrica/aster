import AppKit
import AsterCore

/// 文件查看器的公共文件动作。只交给 Launch Services 打开当前文件，不改系统默认应用。
@MainActor
enum FilePaneFileActions {
  static func menu(url: URL, pasteboard: NSPasteboard = .general, reportError: @escaping (String) -> Void) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let exists = FileManager.default.fileExists(atPath: url.path)
    let reveal = ActionMenuItem(title: L("在访达中显示")) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    reveal.isEnabled = exists
    menu.addItem(reveal)
    menu.addItem(ActionMenuItem(title: L("复制文件路径")) {
      pasteboard.clearContents()
      pasteboard.setString(url.path, forType: .string)
    })
    let open = ActionMenuItem(title: L("使用默认应用打开")) {
      openFile(url, application: nil, reportError: reportError)
    }
    open.isEnabled = exists
    menu.addItem(open)
    let with = NSMenuItem(title: L("打开方式"), action: nil, keyEquivalent: "")
    let applications = NSMenu()
    let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
    for app in NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(20) {
      let name = app.deletingPathExtension().lastPathComponent
      let item = ActionMenuItem(title: name) { openFile(url, application: app, reportError: reportError) }
      item.state = app == defaultApp ? .on : .off
      let icon = NSWorkspace.shared.icon(forFile: app.path)
      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
      applications.addItem(item)
    }
    with.submenu = applications
    with.isEnabled = exists && !applications.items.isEmpty
    menu.addItem(with)
    return menu
  }

  private static func openFile(_ url: URL, application: URL?, reportError: @escaping (String) -> Void) {
    // 与 Files 列表一致：特殊设备不能打开，可执行文件需先由用户确认。
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
      if FileManager.default.isExecutableFile(atPath: url.path) {
        let alert = NSAlert()
        alert.messageText = L("打开可执行文件？")
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: L("打开"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
      }
      Task { @MainActor in
        do {
          if let application {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application,
              configuration: NSWorkspace.OpenConfiguration())
          } else {
            _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
          }
        } catch { reportError(error.localizedDescription) }
      }
    } catch { reportError(error.localizedDescription) }
  }
}
