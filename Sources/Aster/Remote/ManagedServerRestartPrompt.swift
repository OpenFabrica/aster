import AppKit
import AsterCore

// 后台会话服务是旧版本、又有终端在运行时，问用户要不要现在重启服务。

/// 「旧服务」提示窗。重启会结束旧服务里的全部终端，所以必须由用户决定。
@MainActor
enum ManagedServerRestartPrompt {
  /// 显示模态提示；返回 true 表示用户选择现在重启。
  static func run(runningTerminals: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = L("后台会话服务是旧版本")
    alert.informativeText = L(
      "Aster 已更新，但后台会话服务还在运行旧版本，新版本的修复不会生效。现在重启会结束 \(String(runningTerminals)) 个正在运行的终端。选择「以后再说」，下次打开 Aster 时会再提醒。"
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("现在重启"))
    alert.addButton(withTitle: L("以后再说"))
    return alert.runModal() == .alertFirstButtonReturn
  }
}
