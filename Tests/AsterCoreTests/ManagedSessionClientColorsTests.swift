import Foundation
import Testing

@testable import AsterCore

// 客户端主题色文件：格式必须与 SessionRuntime/src/client_colors.zig 的解析一致。

@Test func managedSessionClientColorsUseServerLineFormatWithoutAlpha() {
  let text = ManagedSessionClientColors.text(
    foreground: HexColor(red: 0x17, green: 0x70, blue: 0x3f),
    background: HexColor(red: 0xff, green: 0xff, blue: 0xff, alpha: 0x80),
    cursor: HexColor(red: 0, green: 0, blue: 0))
  #expect(text == "foreground=#17703f\nbackground=#ffffff\ncursor=#000000\n")
}

@Test func managedSessionClientColorsWriteReplacesTheFileInStateParent() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("client-colors-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try ManagedSessionClientColors.write("background=#000000\n", stateParentPath: directory.path)
  try ManagedSessionClientColors.write("background=#ffffff\n", stateParentPath: directory.path)
  let written = try String(
    contentsOf: directory.appendingPathComponent(ManagedSessionClientColors.fileName), encoding: .utf8)
  #expect(written == "background=#ffffff\n")
}
