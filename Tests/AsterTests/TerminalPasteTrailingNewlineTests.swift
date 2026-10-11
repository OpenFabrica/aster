// 粘贴时末尾回车被去掉：只预填输入行，不触发确认，也不执行命令。
import AppKit
import AsterCore
import Testing

@testable import Aster

@Test("粘贴带末尾回车的单行命令只写入正文，不弹确认")
@MainActor
func pasteDropsTrailingNewlineWithoutConfirmation() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  var userBytes: [UInt8] = []
  view.onEncodedInput = { userBytes.append(contentsOf: $0) }
  var confirmationCount = 0
  view.onConfirmPaste = { _ in confirmationCount += 1; return true }

  #expect(view.pasteText("echo hi\r\n\n"))
  #expect(userBytes == Array("echo hi".utf8))
  #expect(confirmationCount == 0)

  // 只有回车的剪贴板不写入任何字节。
  userBytes.removeAll()
  #expect(!view.pasteText("\n\n"))
  #expect(userBytes.isEmpty)
}
