// agent 主机终端对底层终端的最小依赖：敲字、读屏、判断进程是否还活着。
// 生产实现包一个 `TerminalSession`（Ghostty surface 跑 `aster-ssh client`）；
// 测试用模拟 Shell 的替身，不需要真实 PTY。
import AppKit
import AsterCore
import Darwin

/// agent 主机终端看到的终端能力。
@MainActor
protocol AgentHostTerminalSurface: AnyObject {
  /// 把文本当键盘输入写进 PTY；终端只读、处于本地导航模式或进程已退出时返回 false。
  func send(_ text: String) -> Bool
  /// 活动屏幕的纯文本；surface 尚未创建时为 nil。
  func readActiveScreen() -> String?
  /// 含回滚的纯文本，最多 `maximumLines` 行。
  func readScrollback(maximumLines: Int) -> String?
  /// PTY 子进程是否仍在运行。
  var isProcessRunning: Bool { get }
  /// 前台进程是否是原生 SSH 客户端。nil 表示还判断不了（surface 未创建）。
  var isNativeSSHClient: Bool? { get }
  /// 是否处在备用屏（全屏程序）。此时任何注入都可能被当成程序的按键命令。
  var isAlternateScreenActive: Bool { get }
  /// 结束终端进程并释放 surface。
  func terminate()
}

/// 生产实现：独立的 `TerminalSession`，不注册进任何工作区标签。
///
/// 不进 `AppModel` 的标签，`pane.*`、`session.snapshot`、`agent.*` 就都看不到它：
/// agent 只能经 `host.*` 这一条受批准约束的路径操作这个终端。
@MainActor
final class LiveAgentHostTerminalSurface: AgentHostTerminalSurface {
  let session: TerminalSession
  /// 终端视图宿主，由面板控制器挂进窗口。
  let hostView: NSView

  /// 建一个绑定到已保存主机的原生 SSH 会话；工作目录用家目录，与远端无关。
  init(hostID: UUID, preferences: AppPreferences) {
    session = TerminalSession(workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    // 必须在创建 surface（makeTerminalHost）之前绑定，启动命令才会换成 `aster-ssh client`。
    session.bindNativeSSH(.host(hostID))
    hostView = session.makeTerminalHost(preferences: preferences)
  }

  /// 用自动化输入入口写字节：仍经过只读、本地导航模式等门禁。
  func send(_ text: String) -> Bool {
    session.sendAutomationBytes(Array(text.utf8))
  }

  func readActiveScreen() -> String? { session.readActiveScreenText() }

  func readScrollback(maximumLines: Int) -> String? {
    session.readControlText(includeScrollback: true, maximumLines: maximumLines)
  }

  var isProcessRunning: Bool { session.statusIsRunning }

  var isAlternateScreenActive: Bool { session.isAlternateScreenActive }

  /// 用 `proc_pidpath` 看前台进程的可执行名。引擎不可用时 TerminalSession 会回退成
  /// 「本地 Shell 里预填 ssh」，此时前台是 zsh/bash，绝不能把 agent 命令敲进去。
  var isNativeSSHClient: Bool? {
    guard let pid = session.foregroundProcessIdentifier, pid > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path).lastPathComponent == "aster-ssh"
  }

  func terminate() {
    session.onRequestCloseAfterExit = nil
    session.stop(immediately: true)
    hostView.removeFromSuperview()
  }
}
