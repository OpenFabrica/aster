// 将按需读取的目录层合并为 Files 的深度优先快照。
import AsterCore
import Foundation

@MainActor
enum DetailsFileTreeSnapshot {
  /// 只读取根及明确展开的目录；每层完整列出。取消时不再发起后续 I/O，符号链接始终
  /// 作为叶节点，隐藏目录在用户显式展开后与普通目录采用同一规则。
  static func load(
    directory: String, expandedPaths: Set<String>, includeHidden: Bool,
    read: @MainActor (String, Bool) async -> [WorkspaceFileNode]
  ) async -> [WorkspaceFileNode] {
    func visit(_ path: String, depth: Int) async -> [WorkspaceFileNode] {
      guard !Task.isCancelled else { return [] }
      let entries = await read(path, includeHidden)
      var nodes: [WorkspaceFileNode] = []
      for entry in entries {
        guard !Task.isCancelled else { return [] }
        nodes.append(.init(
          path: entry.path, name: entry.name, depth: depth,
          isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink))
        if entry.isDirectory, !entry.isSymbolicLink, expandedPaths.contains(entry.path) {
          nodes += await visit(entry.path, depth: depth + 1)
        }
      }
      return nodes
    }
    return await visit(directory, depth: 0)
  }
}
