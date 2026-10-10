// 字符串编辑距离：纠错规则与包运行器建议共用的「最接近候选」度量。
import Foundation

/// Levenshtein 编辑距离。按 `Character` 计算，输入长度有界时为 O(m·n)；
/// 调用方负责先限制长度（命令名 ≤ 128、目录名 ≤ 255），这里不再截断。
public enum StringEditDistance {
  /// 返回把 `left` 改成 `right` 所需的最少插入/删除/替换次数。
  public static func levenshtein(_ left: String, _ right: String) -> Int {
    let lhs = Array(left)
    let rhs = Array(right)
    if lhs.isEmpty { return rhs.count }
    if rhs.isEmpty { return lhs.count }
    var previous = Array(0...rhs.count)
    for (leftIndex, leftCharacter) in lhs.enumerated() {
      var current = [leftIndex + 1]
      current.reserveCapacity(rhs.count + 1)
      for (rightIndex, rightCharacter) in rhs.enumerated() {
        current.append(
          min(
            current[rightIndex] + 1,
            previous[rightIndex + 1] + 1,
            previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
          ))
      }
      previous = current
    }
    return previous[rhs.count]
  }

  /// 在 `candidates` 里找与 `target` 最接近、且距离不超过 `maximumDistance` 的一项。
  /// 距离相同按字典序取前者，结果因此是确定的。`caseInsensitive` 为真时按小写比较，
  /// 但返回候选的原始写法。
  public static func nearest(
    to target: String,
    in candidates: some Sequence<String>,
    maximumDistance: Int,
    caseInsensitive: Bool = true
  ) -> String? {
    let normalizedTarget = caseInsensitive ? target.lowercased() : target
    var best: (value: String, distance: Int)?
    for candidate in candidates {
      let normalized = caseInsensitive ? candidate.lowercased() : candidate
      let distance = levenshtein(normalizedTarget, normalized)
      guard distance <= maximumDistance else { continue }
      if let current = best {
        if distance < current.distance || (distance == current.distance && candidate < current.value) {
          best = (candidate, distance)
        }
      } else {
        best = (candidate, distance)
      }
    }
    return best?.value
  }

  /// 纠错允许的最大距离：短词只容 1 个错，长词按三分之一放宽，上限 3。
  public static func correctionTolerance(for word: String) -> Int {
    max(1, min(3, word.count / 3 + 1))
  }
}
