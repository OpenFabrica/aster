import AsterCore
import os

// 把终端主题色发布给本机后台会话服务，让受管终端里的程序查得到前景、背景与光标色。

/// 在 Ghostty 配置生成处调用：配置推给 surface 之前，文件里已经是同一套颜色。
///
/// 只服务本机端点；远端机器的服务读不到本机文件，颜色查询照旧不应答。
@MainActor
enum ManagedClientColorsPublisher {
  /// 上次成功写入的内容；相同就不再写，配置每次重建都会走到这里。
  private static var lastPublished: String?
  private static let logger = Logger(subsystem: "io.local.aster-terminal", category: "managed-session")

  /// 写入本机状态目录的 `client-colors`；没有本机端点（开发构建）时什么也不做。
  /// 写入失败只记录日志：颜色应答是增强，不能影响终端配置下发。
  static func publish(foreground: HexColor, background: HexColor, cursor: HexColor) {
    guard let stateParent = ManagedTerminalCoordinator.localStateParentPath else { return }
    let text = ManagedSessionClientColors.text(
      foreground: foreground, background: background, cursor: cursor)
    guard text != lastPublished else { return }
    do {
      try ManagedSessionClientColors.write(text, stateParentPath: stateParent)
      lastPublished = text
    } catch {
      logger.error("client colors write failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
