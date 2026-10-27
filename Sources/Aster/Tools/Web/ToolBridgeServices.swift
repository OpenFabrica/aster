// 桥接用到的系统能力：剪贴板、文件选择框、确认框、系统浏览器与系统通知。抽成协议，测试不碰真实系统界面。
import AppKit
import AsterCore
import UniformTypeIdentifiers
import UserNotifications

/// 一条要发出的工具通知（标题与正文已经过长度与控制字符处理）。
struct ToolNotificationContent: Equatable, Sendable {
  let title: String
  let body: String?
  let pluginID: String
  let pluginName: String
}

/// 桥接需要的系统能力。生产实现是 `SystemToolBridgeServices`，测试注入假实现。
@MainActor
protocol ToolBridgeServices: AnyObject {
  /// 剪贴板里的纯文本；没有文本时为 nil。
  func readClipboardText() -> String?
  /// 用纯文本替换剪贴板内容。
  func writeClipboardText(_ text: String)
  /// 弹出文件选择框（只能选文件）；取消返回空数组。`allowedExtensions` 为空表示不限类型。
  func pickFiles(allowedExtensions: [String], allowsMultiple: Bool, pluginName: String, window: NSWindow?) async
    -> [URL]
  /// 询问用户是否打开插件请求的网址；返回用户是否同意。
  func confirmOpening(_ url: URL, pluginName: String, window: NSWindow?) async -> Bool
  /// 用系统默认浏览器打开网址。
  func openInBrowser(_ url: URL)
  /// 发一条系统通知；没有通知权限或当前构建不支持时抛 `ToolBridgeError`。
  func post(_ notification: ToolNotificationContent) async throws
  /// 工具关闭时收起还挂在窗口上的文件选择框或确认框（按取消处理）。
  func dismissPresentedSheets()
}

/// 真实的系统能力。每个网页工具一个实例，只收起自己弹出的对话框。
@MainActor
final class SystemToolBridgeServices: ToolBridgeServices {
  /// 确认框里网址最多显示的字符数；网址开头的 scheme 与主机总在前面，截断不影响判断去向。
  private static let maximumDisplayedURLLength = 512

  private let pasteboard: NSPasteboard
  /// 当前以 sheet 形式挂着的对话框窗口及其宿主窗口。
  private var presentedSheet: (sheet: NSWindow, parent: NSWindow, cancelCode: NSApplication.ModalResponse)?

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  /// 收起自己弹出的 sheet；没有时什么也不做。
  func dismissPresentedSheets() {
    guard let presentedSheet else { return }
    self.presentedSheet = nil
    presentedSheet.parent.endSheet(presentedSheet.sheet, returnCode: presentedSheet.cancelCode)
  }

  /// 读剪贴板纯文本。
  func readClipboardText() -> String? {
    pasteboard.string(forType: .string)
  }

  /// 写剪贴板纯文本。
  func writeClipboardText(_ text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// 文件选择框挂在工具所在窗口上；没有窗口时以应用模态弹出。
  func pickFiles(allowedExtensions: [String], allowsMultiple: Bool, pluginName: String, window: NSWindow?) async
    -> [URL]
  {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = allowsMultiple
    panel.resolvesAliases = true
    panel.message = L("插件「\(pluginName)」请求读取你选择的文件")
    let types = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    if !types.isEmpty { panel.allowedContentTypes = types }
    let response: NSApplication.ModalResponse
    if let window {
      presentedSheet = (panel, window, .cancel)
      response = await panel.beginSheetModal(for: window)
      if presentedSheet?.sheet === panel { presentedSheet = nil }
    } else {
      response = panel.runModal()
    }
    return response == .OK ? panel.urls : []
  }

  /// 确认框：「插件「X」想打开：」+ 网址，默认按钮是「打开」。
  func confirmOpening(_ url: URL, pluginName: String, window: NSWindow?) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L("插件「\(pluginName)」想打开：")
    let text = url.absoluteString
    alert.informativeText =
      text.count > Self.maximumDisplayedURLLength ? String(text.prefix(Self.maximumDisplayedURLLength)) + "…" : text
    alert.addButton(withTitle: L("打开"))
    alert.addButton(withTitle: L("取消"))
    let response: NSApplication.ModalResponse
    if let window {
      presentedSheet = (alert.window, window, .alertSecondButtonReturn)
      response = await alert.beginSheetModal(for: window)
      if presentedSheet?.sheet === alert.window { presentedSheet = nil }
    } else {
      response = alert.runModal()
    }
    return response == .alertFirstButtonReturn
  }

  /// 交给系统默认浏览器。
  func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  /// 沿用终端通知的授权方式：未决定时请求一次 alert + sound 授权，结果回写 `TerminalNotificationService`
  /// 的缓存状态（设置页据此显示）；副标题写插件名，让用户知道是哪个插件发的。
  func post(_ notification: ToolNotificationContent) async throws {
    // SwiftPM 测试宿主没有 App Bundle，`UNUserNotificationCenter.current()` 会抛 Objective-C 异常。
    guard Bundle.main.bundleIdentifier != nil else {
      throw ToolBridgeError.unavailable(L("当前构建不能发送系统通知"))
    }
    let center = UNUserNotificationCenter.current()
    let status = await center.notificationSettings().authorizationStatus
    switch status {
    case .denied:
      throw ToolBridgeError.unavailable(L("系统通知已在系统设置中关闭"))
    case .notDetermined:
      let allowed: Bool
      do {
        allowed = try await center.requestAuthorization(options: [.alert, .sound])
      } catch {
        allowed = false
      }
      TerminalNotificationService.shared.refreshAuthorizationStatus()
      guard allowed else { throw ToolBridgeError.unavailable(L("没有获得系统通知权限")) }
    default:
      break
    }
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.subtitle = notification.pluginName
    if let body = notification.body { content.body = body }
    let request = UNNotificationRequest(
      identifier: "aster.tool.\(notification.pluginID).\(UUID().uuidString)", content: content, trigger: nil)
    do {
      try await center.add(request)
    } catch {
      throw ToolBridgeError.failed(L("发送通知失败"))
    }
  }
}
