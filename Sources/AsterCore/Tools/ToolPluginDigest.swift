// 插件目录摘要：用户来源插件授权后，用它判断文件有没有被改过。
import CryptoKit
import Foundation

/// 插件目录摘要。
public enum ToolPluginDigest {
  public static let maximumFileCount = 2_000
  public static let maximumTotalBytes = 50 * 1_048_576
  /// 摘要里跳过的文件名（Finder 随手生成，与插件内容无关）。
  static let ignoredFileNames: Set<String> = [".DS_Store"]

  /// 摘要失败的原因。关联值是相对插件目录的路径。
  public enum Failure: Error, Equatable, Sendable {
    case unreadable(String)
    case symbolicLink(String)
    case tooManyFiles
    case tooLarge
  }

  /// 遍历插件目录的所有普通文件（跳过 `.DS_Store`，包含其他隐藏文件），按相对路径的 UTF-8 字节序排序，
  /// 依次把「相对路径 + 0x00 + 十进制长度 + 0x00 + 内容」送入 SHA-256，返回小写十六进制摘要。
  /// 遇到符号链接、超过 2,000 个文件或 50 MiB 直接报错；目录本身可以是符号链接（例如登记的开发目录）。
  public static func compute(directory: URL, fileManager: FileManager = .default) throws -> String {
    guard let root = canonicalPath(directory.path) else { throw Failure.unreadable(directory.path) }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw Failure.unreadable(directory.path)
    }
    let files = try regularFiles(root: root, fileManager: fileManager)
    var hasher = SHA256()
    for file in files.sorted(by: { $0.relative.utf8.lexicographicallyPrecedes($1.relative.utf8) }) {
      try hash(file, root: root, into: &hasher)
    }
    return BuiltinTextTools.hex(hasher.finalize())
  }

  /// 遍历时记下的一个普通文件。
  private struct Entry {
    let relative: String
    let size: Int
  }

  /// 深度优先列出普通文件；目录读不了、出现符号链接或超出上限时报错。
  /// 不用 FileManager 的枚举器：它会静默跳过读不了的子目录，摘要就可能漏掉文件。
  private static func regularFiles(root: String, fileManager: FileManager) throws -> [Entry] {
    var files: [Entry] = []
    var total = 0
    var pending = [""]
    while let relativeDirectory = pending.popLast() {
      let names: [String]
      do {
        names = try fileManager.contentsOfDirectory(atPath: join(root, relativeDirectory))
      } catch {
        throw Failure.unreadable(relativeDirectory.isEmpty ? "." : relativeDirectory)
      }
      for name in names where !ignoredFileNames.contains(name) {
        let relative = join(relativeDirectory, name)
        let attributes: [FileAttributeKey: Any]
        do {
          // attributesOfItem 不跟随符号链接，拿到的是链接本身的类型。
          attributes = try fileManager.attributesOfItem(atPath: join(root, relative))
        } catch {
          throw Failure.unreadable(relative)
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
          throw Failure.symbolicLink(relative)
        case .typeDirectory?:
          pending.append(relative)
        case .typeRegular?:
          let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
          files.append(Entry(relative: relative, size: size))
          total += size
          if files.count > maximumFileCount { throw Failure.tooManyFiles }
          if total > maximumTotalBytes { throw Failure.tooLarge }
        default:
          // 管道、套接字等特殊文件不是插件内容，也不能去读（读管道会一直阻塞），直接跳过。
          continue
        }
      }
    }
    return files
  }

  /// 把一个文件送入摘要。以 `O_NOFOLLOW` 打开并流式读取：遍历之后才被换成符号链接的文件不会被跟随，
  /// 大小与遍历时不同（文件正在被改）则报错，避免算出一个与任何时刻都不一致的摘要。
  private static func hash(_ file: Entry, root: String, into hasher: inout SHA256) throws {
    let descriptor = open(join(root, file.relative), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw errno == ELOOP ? Failure.symbolicLink(file.relative) : Failure.unreadable(file.relative)
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) == file.size else {
      throw Failure.unreadable(file.relative)
    }
    hasher.update(data: Data(file.relative.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(String(file.size).utf8))
    hasher.update(data: Data([0]))
    var remaining = file.size
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while remaining > 0 {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, min($0.count, remaining)) }
      if count < 0, errno == EINTR { continue }
      // 读错或提前读到文件尾（文件被截短）都说明内容不可信。
      guard count > 0 else { throw Failure.unreadable(file.relative) }
      buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
      remaining -= count
    }
  }

  /// 解析符号链接后的绝对路径；路径不存在时为 nil。用 realpath 而不是 URL 的解析，后者会去掉 `/private` 前缀。
  static func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// 拼接相对路径，空串表示根目录本身。
  private static func join(_ base: String, _ name: String) -> String {
    if base.isEmpty { return name }
    if name.isEmpty { return base }
    return base.hasSuffix("/") ? base + name : base + "/" + name
  }
}
