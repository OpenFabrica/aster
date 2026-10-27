// 插件目录摘要：确定性、跳过 .DS_Store、内容与路径变化敏感、拒绝符号链接、数量与体积上限。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolPluginDigest")
struct ToolPluginDigestTests {
  /// 在临时目录里建一个插件目录，`body` 结束后删除。
  private func withPlugin(_ files: [String: String], _ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for (path, content) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body(root)
  }

  /// 同样的内容得到同样的摘要；`.DS_Store` 与空目录不影响结果；摘要是 64 位小写十六进制。
  @Test func digestIsDeterministicAndIgnoresDSStore() throws {
    let files = ["aster-plugin.json": "{}", "web/index.html": "<p>", "web/app.js": "1", ".hidden": "h"]
    var digests: [String] = []
    try withPlugin(files) { digests.append(try ToolPluginDigest.compute(directory: $0)) }
    try withPlugin(files.merging(["web/.DS_Store": "junk", ".DS_Store": "x"]) { $1 }) { root in
      try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
      digests.append(try ToolPluginDigest.compute(directory: root))
    }
    #expect(digests[0] == digests[1])
    #expect(digests[0].count == 64)
    #expect(digests[0].allSatisfy { "0123456789abcdef".contains($0) })
  }

  /// 摘要等于按字节序把「路径 0x00 长度 0x00 内容」依次送入 SHA-256 的结果。
  @Test func digestMatchesDocumentedFormat() throws {
    try withPlugin(["b.txt": "BB", "a/z.txt": "Z"]) { root in
      var expected = Data()
      for (path, content) in [("a/z.txt", "Z"), ("b.txt", "BB")] {
        expected += Data(path.utf8) + Data([0]) + Data(String(content.utf8.count).utf8) + Data([0]) + Data(content.utf8)
      }
      let hash = BuiltinTextTools.hashes(of: expected).first { $0.label == "SHA-256" }?.value
      let digest = try ToolPluginDigest.compute(directory: root)
      #expect(digest == hash)
    }
  }

  /// 内容、文件名或隐藏文件变化都会改变摘要。
  @Test func digestChangesWithContentNameOrHiddenFiles() throws {
    let base = ["index.html": "a", "lib/x.js": "b"]
    var digests: [String] = []
    for files in [base, ["index.html": "A", "lib/x.js": "b"], ["index.html": "a", "lib/y.js": "b"], base.merging([".env": "k"]) { $1 }] {
      try withPlugin(files) { digests.append(try ToolPluginDigest.compute(directory: $0)) }
    }
    #expect(Set(digests).count == digests.count)
  }

  /// 目录里有符号链接直接报错；插件目录本身是符号链接则允许。
  @Test func symbolicLinks() throws {
    try withPlugin(["index.html": "a"]) { root in
      let link = root.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
      defer { try? FileManager.default.removeItem(at: link) }
      let viaLink = try ToolPluginDigest.compute(directory: link)
      #expect(viaLink == (try ToolPluginDigest.compute(directory: root)))
      try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("secret").path, withDestinationPath: "/etc/hosts")
      #expect(throws: ToolPluginDigest.Failure.symbolicLink("secret")) { try ToolPluginDigest.compute(directory: root) }
    }
  }

  /// 文件数超过 2,000、总大小超过 50 MiB、目录不存在时报错。
  @Test func limitsAndMissingDirectory() throws {
    try withPlugin([:]) { root in
      for index in 0...ToolPluginDigest.maximumFileCount {
        try Data().write(to: root.appendingPathComponent("f\(index)"))
      }
      #expect(throws: ToolPluginDigest.Failure.tooManyFiles) { try ToolPluginDigest.compute(directory: root) }
    }
    try withPlugin(["small": "x"]) { root in
      // 稀疏文件：只设大小不写内容，几乎不占磁盘。
      let big = root.appendingPathComponent("big.bin")
      FileManager.default.createFile(atPath: big.path, contents: nil)
      let handle = try FileHandle(forWritingTo: big)
      try handle.truncate(atOffset: UInt64(ToolPluginDigest.maximumTotalBytes))
      try handle.close()
      #expect(throws: ToolPluginDigest.Failure.tooLarge) { try ToolPluginDigest.compute(directory: root) }
    }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
    #expect(throws: ToolPluginDigest.Failure.self) { try ToolPluginDigest.compute(directory: missing) }
  }
}
