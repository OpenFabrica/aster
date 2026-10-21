// 命令词的末段名：只做字符串切分，不经过 URL 解析。
import Foundation

extension ShellCommandTokenizer {
  /// 返回命令词按 `/` 切分后的最后一段（`/usr/bin/git` → `git`），用来识别可执行名。
  ///
  /// 不能用 `URL(fileURLWithPath:).lastPathComponent`：按 macOS 14 SDK 链接的进程（正式包就是）
  /// 里，系统 Foundation 遇到以 `http:` / `https:` 开头、又解析不成 URL 的字符串
  /// （如 `http://127.0.0.1:${PORT}/healthz`）会直接 fatalError，整个应用闪退（Sentry ASTER-A）。
  /// 命令词来自用户、agent 或进程表的任意输入，所以只走 `NSString` 的纯路径字符串处理。
  public static func basename(_ word: String) -> String {
    (word as NSString).lastPathComponent
  }
}
