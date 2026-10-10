import Foundation
import Testing

@testable import AsterCore

@Test("可执行文件索引只收可执行的普通文件与链接，支持前缀查询与指纹")
func executableIndexBuildsFromDirectories() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-exec-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let bin = root.appendingPathComponent("bin")
  try FileManager.default.createDirectory(at: bin.appendingPathComponent("sub.d"), withIntermediateDirectories: true)
  func create(_ name: String, executable: Bool) throws {
    let url = bin.appendingPathComponent(name)
    try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
  }
  try create("zzrg", executable: true)
  try create("zzfd", executable: true)
  try create("notes.txt", executable: false)
  try create("bad name", executable: true)
  try FileManager.default.createSymbolicLink(
    at: bin.appendingPathComponent("zzlink"), withDestinationURL: bin.appendingPathComponent("zzrg"))
  try FileManager.default.createSymbolicLink(
    at: bin.appendingPathComponent("dirlink"), withDestinationURL: bin.appendingPathComponent("sub.d"))

  let index = AutocompleteExecutableIndex.build(directories: [bin.path, "/nonexistent/bin"])
  #expect(index.names == ["zzfd", "zzlink", "zzrg"])
  #expect(index.contains("zzrg"))
  #expect(!index.contains("notes.txt"))
  #expect(!index.contains("sub.d"))
  #expect(Array(index.names(withPrefix: "zzr")) == ["zzrg"])
  #expect(Array(index.names(withPrefix: "zz")) == ["zzfd", "zzlink", "zzrg"])
  #expect(index.names(withPrefix: "q").isEmpty)
  #expect(index.directories == [bin.path, "/nonexistent/bin"])
  #expect(index.fingerprints.count == 2)
  #expect(index.fingerprints[1] == "/nonexistent/bin:-")
  #expect(AutocompleteExecutableIndex.empty.names(withPrefix: "").isEmpty)
}
