// 面板 ⇧⌫「从历史中删除」的领域动作：压制某个槽位上的某个历史值，以及它的上限与校验。
import Foundation

extension AutocompleteLearningDatabase {
  /// 最多压制多少个槽位；每个槽位最多多少个值；单个值最长多少字节。
  public static let maximumSuppressedSlots = 500
  public static let maximumSuppressedValuesPerSlot = 200
  public static let maximumSuppressedValueBytes = 256

  /// 忘记槽位上的一个历史值（`git checkout <分支>` 里的某个分支名、某个用过的命令名）。
  /// 历史条目本身保留——同一条整行可能还服务于别的槽位；只是这个值不再作为候选出现。
  /// 超出容量时拒绝并返回 false，不静默丢弃别的压制。
  @discardableResult
  public mutating func suppress(slot: String, value: String) -> Bool {
    guard !slot.isEmpty, !value.isEmpty, value.utf8.count <= Self.maximumSuppressedValueBytes else { return false }
    var table = suppressedValues ?? [:]
    var values = table[slot] ?? []
    if values.contains(value) { return true }
    guard table[slot] != nil || table.count < Self.maximumSuppressedSlots,
      values.count < Self.maximumSuppressedValuesPerSlot
    else { return false }
    values.insert(value)
    table[slot] = values
    suppressedValues = table
    return true
  }

  /// 用户又真的执行了含这个值的命令：压制自动解除。`slots` 是这条命令的全部 (槽位, 值)。
  public mutating func unsuppress(slots: [(slot: String, value: String)]) {
    guard var table = suppressedValues else { return }
    for (slot, value) in slots {
      guard var values = table[slot], values.remove(value) != nil else { continue }
      if values.isEmpty { table.removeValue(forKey: slot) } else { table[slot] = values }
    }
    suppressedValues = table.isEmpty ? nil : table
  }

  /// 某槽位上的值是否被压制。
  public func isSuppressed(slot: String, value: String) -> Bool {
    suppressedValues?[slot]?.contains(value) == true
  }

  /// 反序列化校验：容量与单值长度都在上限内。
  static func suppressedValuesAreValid(_ table: [String: Set<String>]?) -> Bool {
    guard let table else { return true }
    return table.count <= maximumSuppressedSlots
      && table.allSatisfy { slot, values in
        !slot.isEmpty && !values.isEmpty && values.count <= maximumSuppressedValuesPerSlot
          && values.allSatisfy { !$0.isEmpty && $0.utf8.count <= maximumSuppressedValueBytes }
      }
  }
}
