// 自动补全清理的五个独立数据范围；不包含内置命令规格或通用 CLI 状态。
import Foundation

/// 空集合不产生写入；每种范围独立清理，成功范围可组成返回掩码。
public struct AutocompleteClearSelection: OptionSet, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let history = Self(rawValue: 1 << 0)
  public static let fullLines = Self(rawValue: 1 << 1)
  public static let helpProbe = Self(rawValue: 1 << 2)
  public static let learnedFolder = Self(rawValue: 1 << 3)
  public static let learnedSpecs = Self(rawValue: 1 << 4)
  public static let all: Self = [.history, .fullLines, .helpProbe, .learnedFolder, .learnedSpecs]
}
