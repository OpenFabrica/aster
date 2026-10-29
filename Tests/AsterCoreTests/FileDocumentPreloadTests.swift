// Files 预览槽后台预读：文本类型读入缓冲，其余类型只分类，特殊文件与超大文件不读取。
import Darwin
import Foundation
import Testing

@testable import AsterCore

/// 建一个独立临时目录，调用方在 `defer` 中删除。
private func preloadFixtureDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-preload-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

@Test(
  "文本类型预读后带文档缓冲",
  arguments: [
    ("README.md", FilePresentationKind.markdown),
    ("data.json", .json),
    ("main.swift", .sourceText),
    ("NOTES", .sourceText),
  ])
func textKindsPreloadDocumentBuffer(name: String, kind: FilePresentationKind) throws {
  let root = try preloadFixtureDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent(name)
  let content = "第一行 preview\nsecond line\n"
  try Data(content.utf8).write(to: url)
  let preload = try #require(FileDocumentPreload.load(url))
  #expect(preload.url == url)
  #expect(preload.presentationKind == kind)
  #expect(preload.fileSize == content.utf8.count)
  #expect(preload.modificationDate != nil)
  guard case .success(let buffer) = preload.document else {
    Issue.record("文本类型应读入缓冲，实际为 \(String(describing: preload.document))")
    return
  }
  #expect(buffer.text == content)
  #expect(!buffer.isDirty)
}

@Test("图片与二进制只分类，不读文本缓冲")
func imageAndBinaryHaveNoDocument() throws {
  let root = try preloadFixtureDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let image = root.appendingPathComponent("logo.png")
  try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: image)
  let binary = root.appendingPathComponent("payload.bin")
  try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: binary)
  let imagePreload = try #require(FileDocumentPreload.load(image))
  #expect(imagePreload.presentationKind == .image)
  #expect(imagePreload.document == nil)
  let binaryPreload = try #require(FileDocumentPreload.load(binary))
  #expect(binaryPreload.presentationKind == .binary)
  #expect(binaryPreload.document == nil)
  #expect(binaryPreload.fileSize == 5)
}

@Test("符号链接、目录与 FIFO 不预读")
func specialFilesReturnNil() throws {
  let root = try preloadFixtureDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appendingPathComponent("target.txt")
  try Data("secret".utf8).write(to: target)
  let link = root.appendingPathComponent("link.txt")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  let directory = root.appendingPathComponent("folder")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  let fifo = root.appendingPathComponent("pipe.txt")
  #expect(mkfifo(fifo.path, 0o600) == 0)
  #expect(FileDocumentPreload.load(link) == nil)
  #expect(FileDocumentPreload.load(directory) == nil)
  // FIFO 若被打开读取会一直阻塞；返回 nil 说明预读在打开前就拒绝了它。
  #expect(FileDocumentPreload.load(fifo) == nil)
  #expect(FileDocumentPreload.load(root.appendingPathComponent("missing.txt")) == nil)
}

@Test("超过 10 MiB 的文本返回 tooLarge 而不抛错")
func oversizedTextReportsTooLarge() throws {
  let root = try preloadFixtureDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("huge.txt")
  #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
  // 稀疏文件：只改逻辑长度，不真正写入 10 MiB 数据。
  let handle = try FileHandle(forWritingTo: url)
  try handle.truncate(atOffset: UInt64(FileDocumentPreload.maximumTextBytes + 1))
  try handle.close()
  let preload = try #require(FileDocumentPreload.load(url))
  #expect(preload.presentationKind == .sourceText)
  #expect(preload.fileSize == FileDocumentPreload.maximumTextBytes + 1)
  #expect(preload.document == .failure(.tooLarge))
}

@Test("文本扩展名但内容不是 UTF-8 时返回 unreadable")
func invalidUTF8TextReportsUnreadable() throws {
  let root = try preloadFixtureDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("latin1.txt")
  try Data([0x66, 0x6F, 0xFF, 0xFE, 0x6F]).write(to: url)
  let preload = try #require(FileDocumentPreload.load(url))
  guard case .failure(.unreadable) = preload.document else {
    Issue.record("应为 unreadable，实际为 \(String(describing: preload.document))")
    return
  }
}

@Test("可信 Agent 记录按 agentTranscript 预读")
func trustedAgentProviderClassifiesTranscript() throws {
  let root = try preloadFixtureDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("session.jsonl")
  try Data("{\"type\":\"user\"}\n".utf8).write(to: url)
  let provider = try #require(AgentProvider.allCases.first)
  let preload = try #require(FileDocumentPreload.load(url, trustedAgentProvider: provider))
  #expect(preload.presentationKind == .agentTranscript)
  guard case .success = preload.document else {
    Issue.record("Agent 记录是文本类型，应读入缓冲")
    return
  }
}
