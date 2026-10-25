// 原生动态提供器与候选合成之间的纯值边界。
import Foundation

public struct CompletionDynamicItem: Equatable, Sendable {
  public var name: String
  public var displayText: String
  public var description: String
  public var kind: AutocompleteCandidateKind
  public var clearLeader: Bool

  /// name 是未做 Shell 转义的插入值；前缀过滤、替换位置和转义由候选引擎处理。
  public init(name: String, displayText: String? = nil, description: String = "",
    kind: AutocompleteCandidateKind = .dynamicArgument, clearLeader: Bool = false)
  {
    self.name = name
    self.displayText = displayText ?? name
    self.description = description
    self.kind = kind
    self.clearLeader = clearLeader
  }
}
