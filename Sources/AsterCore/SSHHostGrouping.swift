import Foundation

// 主机页分组的编辑规则：新建、重命名、删除。分组没有独立实体——平时由主机的 `group`
// 字段推出，空分组靠快照里「声明的分组」存在——所以这三个动作都是对整份快照的纯变换，
// App 层拿到结果再落盘。

/// 分组编辑失败的原因。
public enum SSHHostGroupingError: Error, Equatable, Sendable {
  /// 名称为空（只有空白也算）。
  case emptyName
  /// 名称过长或含换行。
  case invalidName
  /// 涉及 `~/.ssh/config` 导入组：它由导入流程按名字识别，不能手工新建、改名或删除。
  case reserved
  /// 已有同名分组。
  case alreadyExists(String)
  /// 要改名或删除的分组不存在。
  case unknownGroup
}

/// 分组编辑规则。全部是纯函数，不碰文件。
public enum SSHHostGrouping {
  /// 当前存在的全部分组：主机推出的 ∪ 声明的（不含默认项）。
  public static func existingGroups(in snapshot: SSHHostSnapshot) -> Set<String> {
    Set(snapshot.hosts.filter { !$0.isDefaults }.compactMap(\.group)).union(snapshot.groups)
  }

  /// 新建一个空分组：只在声明列表里追加一条。
  public static func create(_ name: String, in snapshot: SSHHostSnapshot) throws -> SSHHostSnapshot {
    let name = try validated(name)
    guard !existingGroups(in: snapshot).contains(name) else {
      throw SSHHostGroupingError.alreadyExists(name)
    }
    var next = snapshot
    next.groups.append(name)
    return next
  }

  /// 重命名分组：组内每台主机的 `group` 一起改；改过名的分组进入声明列表，之后删空也还在。
  /// 新旧名相同时原样返回。
  public static func rename(
    _ old: String, to new: String, in snapshot: SSHHostSnapshot
  ) throws -> SSHHostSnapshot {
    let new = try validated(new)
    guard old != SSHHostProfile.importedGroup else { throw SSHHostGroupingError.reserved }
    let existing = existingGroups(in: snapshot)
    guard existing.contains(old) else { throw SSHHostGroupingError.unknownGroup }
    guard new != old else { return snapshot }
    guard !existing.contains(new) else { throw SSHHostGroupingError.alreadyExists(new) }
    var next = snapshot
    next.hosts = next.hosts.map { host in
      guard host.group == old else { return host }
      var copy = host
      copy.group = new
      return copy
    }
    next.groups = next.groups.filter { $0 != old } + [new]
    return next
  }

  /// 删除分组：组内主机变成未分组（主机本身保留），声明列表里去掉它。
  public static func delete(_ name: String, in snapshot: SSHHostSnapshot) throws -> SSHHostSnapshot {
    guard name != SSHHostProfile.importedGroup else { throw SSHHostGroupingError.reserved }
    guard existingGroups(in: snapshot).contains(name) else { throw SSHHostGroupingError.unknownGroup }
    var next = snapshot
    next.hosts = next.hosts.map { host in
      guard host.group == name else { return host }
      var copy = host
      copy.group = nil
      return copy
    }
    next.groups.removeAll { $0 == name }
    return next
  }

  /// 去空白后检查名称：空、过长或含换行、等于导入组名都拒绝。
  private static func validated(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SSHHostGroupingError.emptyName }
    guard SSHHostStore.groupNameIsValid(trimmed) else { throw SSHHostGroupingError.invalidName }
    guard trimmed != SSHHostProfile.importedGroup else { throw SSHHostGroupingError.reserved }
    return trimmed
  }
}
