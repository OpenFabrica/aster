import Foundation

// 受管终端的客户端主题色：写给本机 aster-session，让它按输出顺序应答颜色查询。

/// 本机会话状态目录里的 `client-colors`：当前终端主题的前景、背景与光标色。
///
/// 受管终端的权威 VT 在 aster-session 里，它不知道客户端主题，以前受管 Pane 里的程序
/// 查不到背景色（OSC 11），Claude Code 因此退回深色主题。服务端每次应答前按修改时间
/// 重读这个文件；格式与解析见 `SessionRuntime/src/client_colors.zig`。
///
/// 调用方必须在把新主题推给 Ghostty 之前写入：Ghostty 切换主题时会立即按 mode 2031
/// 通知程序，程序随即重新查询，届时文件里必须已是新颜色。
public enum ManagedSessionClientColors {
  public static let fileName = "client-colors"

  /// 文件内容：每行 `键=#rrggbb`，忽略透明度（OSC 应答只有 RGB）。
  public static func text(foreground: HexColor, background: HexColor, cursor: HexColor) -> String {
    func hex(_ color: HexColor) -> String {
      String(format: "#%02x%02x%02x", color.red, color.green, color.blue)
    }
    return "foreground=\(hex(foreground))\nbackground=\(hex(background))\ncursor=\(hex(cursor))\n"
  }

  /// 原子写入 `<stateParent>/client-colors`，服务端不会读到半个文件。
  ///
  /// - Throws: 目录不存在或写入失败时抛出文件系统错误。
  public static func write(_ text: String, stateParentPath: String) throws {
    let url = URL(fileURLWithPath: stateParentPath).appendingPathComponent(fileName)
    try Data(text.utf8).write(to: url, options: .atomic)
  }
}
