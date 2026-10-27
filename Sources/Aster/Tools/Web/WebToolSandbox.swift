// 网页工具沙箱在 CSP 之外的加固：关闭 WebRTC。
// WebRTC 的 STUN/TURN 连接不受 CSP `connect-src` 约束，页面可以借它把数据带到任意主机，绕过 `network` 权限；
// CSP 的 `frame-src 'none'` 也挡不住脚本创建的 about:blank iframe（它不经过网络加载），所以两层都覆盖所有 frame。
import WebKit

/// 网页工具 WebView 的额外沙箱设置。
@MainActor
enum WebToolSandbox {
  /// 每个 frame（含脚本创建的 about:blank iframe）文档开始时执行：把 WebRTC 构造函数换成只读的 undefined。
  /// 个别属性无法重定义时继续处理其余属性，由引擎层开关兜底。源码是常量，不拼接任何数据。
  static let hardeningScript = """
    (() => {
      "use strict";
      for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection"]) {
        try {
          Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false, enumerable: false });
        } catch (error) {
          console.error(error);
        }
      }
    })();
    """

  /// 引擎层关闭 WebRTC。WebKit 没有公开开关，这里用私有偏好 `_setPeerConnectionEnabled:`
  /// （与设置页给 WKWebView 设 `drawsBackground` 同类做法）；先确认它存在，系统去掉它时只剩脚本这一层，不会崩溃。
  static func disablePeerConnections(in preferences: WKPreferences) {
    guard preferences.responds(to: Selector(("_setPeerConnectionEnabled:"))) else { return }
    preferences.setValue(false, forKey: "peerConnectionEnabled")
  }

  /// 文档开始时注入到所有 frame 的加固脚本。
  static func makeHardeningUserScript() -> WKUserScript {
    WKUserScript(source: hardeningScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
  }
}
