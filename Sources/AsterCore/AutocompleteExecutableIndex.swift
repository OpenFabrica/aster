// PATH 目录里可执行文件名的索引：补全规格库没有的程序名，并回答「这是不是一条命令」。
import Foundation

/// 由 Shell 上报的 `$PATH` 目录建成的可执行文件名索引。不可变值类型：后台线程建好后
/// 整体换入，主线程只读；`fingerprints` 是各目录的 (mtime, size)，用来判断要不要重建。
public struct AutocompleteExecutableIndex: Equatable, Sendable {
  public static let maximumNames = 20_000
  public static let maximumDirectories = 64

  public let directories: [String]
  /// 已排序去重，供前缀二分。
  public let names: [String]
  public let fingerprints: [String]
  private let nameSet: Set<String>

  public static let empty = AutocompleteExecutableIndex(directories: [], names: [], fingerprints: [])

  public init(directories: [String], names: [String], fingerprints: [String]) {
    self.directories = directories
    nameSet = Set(names)
    self.names = nameSet.sorted()
    self.fingerprints = fingerprints
  }

  public func contains(_ name: String) -> Bool { nameSet.contains(name) }

  /// 以 `prefix` 开头的名字（已排序）。空前缀返回全部。
  public func names(withPrefix prefix: String) -> ArraySlice<String> {
    var low = 0
    var high = names.count
    // 第一个 >= prefix 的位置。
    while low < high {
      let middle = (low + high) / 2
      if names[middle] < prefix { low = middle + 1 } else { high = middle }
    }
    var end = low
    while end < names.count, names[end].hasPrefix(prefix) { end += 1 }
    return names[low..<end]
  }

  /// 扫描目录，只收普通可执行文件与指向可执行文件的符号链接，名字必须是裸二进制名。
  /// 在后台线程调用；只用 `FileManager.default` 的无状态读取。
  public static func build(directories: [String]) -> AutocompleteExecutableIndex {
    let fileManager = FileManager.default
    let scoped = Array(directories.prefix(maximumDirectories))
    var names: Set<String> = []
    for directory in scoped {
      guard let entries = try? fileManager.contentsOfDirectory(
        at: URL(fileURLWithPath: directory),
        includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsSubdirectoryDescendants])
      else { continue }
      for url in entries {
        guard names.count < maximumNames else { break }
        let name = url.lastPathComponent
        guard AutocompleteLearnTarget.isBareBinaryName(name), !names.contains(name),
          let values = try? url.resourceValues(forKeys: [.isExecutableKey, .isRegularFileKey, .isSymbolicLinkKey])
        else { continue }
        if values.isSymbolicLink == true {
          // 链接要跟到目标：目标必须是可执行的普通文件，指向目录的链接不算命令。
          var isDirectory: ObjCBool = false
          guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
            fileManager.isExecutableFile(atPath: url.path)
          else { continue }
        } else {
          guard values.isRegularFile == true, values.isExecutable == true else { continue }
        }
        names.insert(name)
      }
    }
    return AutocompleteExecutableIndex(
      directories: scoped, names: Array(names), fingerprints: fingerprints(for: scoped))
  }

  /// 各目录的 (mtime, size) 指纹，只 stat 目录本身。装卸工具会改目录 mtime，足够判断是否重扫。
  public static func fingerprints(for directories: [String]) -> [String] {
    directories.prefix(maximumDirectories).map { directory in
      guard let values = try? URL(fileURLWithPath: directory).resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey,
      ]) else { return "\(directory):-" }
      let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      return "\(directory):\(stamp):\(values.fileSize ?? 0)"
    }
  }
}
