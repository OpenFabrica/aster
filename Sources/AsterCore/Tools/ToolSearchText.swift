// 搜索用的文本归一化：大小写、变音、全半角折叠，词首标记，以及汉字的拼音全拼与首字母。结果按原文缓存。
import Foundation
import os

/// 一种可供模糊匹配的形态：折叠后的标量序列（已去掉空白）与逐位的词首标记。
struct ToolSearchForm: Equatable, Sendable {
  let scalars: [Unicode.Scalar]
  /// 与 `scalars` 等长：该位置是不是词首（开头、空白或标点之后、每个汉字、字母数字切换、驼峰）。
  let boundaries: [Bool]
  /// `scalars` 拼成的整串，用于前缀与完全命中比较。
  let compact: String
}

/// 一个字段（标题、关键词、插件名、副标题）的全部可匹配形态。
struct ToolSearchText: Equatable, Sendable {
  let original: ToolSearchForm
  /// 含汉字时的拼音全拼形态，每个音节首字母都是词首；不含汉字为 nil。
  let pinyin: ToolSearchForm?
  /// 含汉字时每个音节或单词的首字母，例如「时间戳转换」→ `sjczh`；不含汉字为 nil。
  let initials: String?
}

/// 归一化与缓存。字段文本来自已安装插件，数量有限，按原文缓存后每次搜索只剩字典查找。
enum ToolSearchNormalizer {
  static let foldingOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
  static let maximumCachedTexts = 8_192
  private static let cache = OSAllocatedUnfairLock(initialState: [String: ToolSearchText]())

  /// 取字段的搜索形态，必要时计算并缓存。拼音转换较慢，所以在锁外计算，只在读写字典时持锁。
  static func text(for string: String) -> ToolSearchText {
    if let cached = cache.withLock({ $0[string] }) { return cached }
    let computed = make(string)
    cache.withLock { storage in
      // 超过上限说明字段在频繁变化（例如反复切换界面语言），整表清空即可，不做 LRU。
      if storage.count >= maximumCachedTexts { storage.removeAll(keepingCapacity: true) }
      storage[string] = computed
    }
    return computed
  }

  /// 查询按空白拆成词，每个词只做折叠，不做拼音转换（用户输入拼音时去比对字段的拼音形态）。
  static func queryTokens(_ query: String) -> [[Unicode.Scalar]] {
    query.folding(options: foldingOptions, locale: nil)
      .split(whereSeparator: \.isWhitespace)
      .map { Array($0.unicodeScalars) }
  }

  /// 计算字段的全部形态；不含汉字时只有原文形态。
  static func make(_ string: String) -> ToolSearchText {
    let original = form(of: string)
    guard string.unicodeScalars.contains(where: isHan),
      let latin = string.applyingTransform(.mandarinToLatin, reverse: false)
    else { return ToolSearchText(original: original, pinyin: nil, initials: nil) }
    // 转换结果形如「Base64 biān jiě mǎ」：音节之间有空格，折叠后去掉声调，空格处就是音节词首。
    let pinyin = form(of: latin)
    let initials = latin.folding(options: foldingOptions, locale: nil)
      .split(whereSeparator: \.isWhitespace)
      .compactMap { $0.unicodeScalars.first(where: isWordCharacter) }
    return ToolSearchText(original: original, pinyin: pinyin, initials: String(String.UnicodeScalarView(initials)))
  }

  /// 折叠成小写、无变音、半角的标量序列并去掉空白，同时标出词首。
  static func form(of string: String) -> ToolSearchForm {
    let source = Array(string.unicodeScalars)
    let folded = Array(string.folding(options: foldingOptions, locale: nil).unicodeScalars)
    // 折叠前后标量数一致（绝大多数情况）时，才能逐位借原文的大小写识别驼峰词首。
    let cased: [Unicode.Scalar]? = source.count == folded.count ? source : nil
    var scalars: [Unicode.Scalar] = []
    var boundaries: [Bool] = []
    scalars.reserveCapacity(folded.count)
    boundaries.reserveCapacity(folded.count)
    var previousIndex: Int?
    var afterSpace = true
    for (index, scalar) in folded.enumerated() {
      if scalar.properties.isWhitespace {
        afterSpace = true
        continue
      }
      let boundary: Bool
      if let previousIndex, !afterSpace {
        let camel = cased.map { isLowercase($0[previousIndex]) && isUppercase($0[index]) } ?? false
        boundary = camel || isBoundary(previous: folded[previousIndex], current: scalar)
      } else {
        boundary = true
      }
      scalars.append(scalar)
      boundaries.append(boundary)
      previousIndex = index
      afterSpace = false
    }
    return ToolSearchForm(
      scalars: scalars, boundaries: boundaries, compact: String(String.UnicodeScalarView(scalars)))
  }

  /// 相邻两个非空白标量之间是否开始一个新词：每个汉字单独成词，标点之后、字母数字切换处也是词首。
  private static func isBoundary(previous: Unicode.Scalar, current: Unicode.Scalar) -> Bool {
    if isHan(current) || isHan(previous) { return isWordCharacter(current) }
    if !isWordCharacter(previous) { return isWordCharacter(current) }
    return isDigit(previous) != isDigit(current) && isWordCharacter(current)
  }

  /// 汉字（CJK 表意文字）。
  static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isIdeographic
  }

  /// 字母、数字或汉字。
  static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isAlphabetic || scalar.properties.numericType != nil
  }

  /// 数字（不含汉字数字，它们按汉字处理）。
  private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.numericType != nil && !isHan(scalar)
  }

  /// 小写字母。
  private static func isLowercase(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isLowercase
  }

  /// 大写字母。
  private static func isUppercase(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isUppercase
  }
}
