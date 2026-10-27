// 内容匹配：把输入当作待处理内容，逐条执行功能的 match 规则，推荐能处理它的工具（「识别到」）。
import Foundation

extension ToolMatcher {
  /// 内容匹配：返回能处理输入的功能。每个功能取命中规则里等级最高的一条（regex > files > text，同级取靠前的），
  /// regex 命中永远排在 text 之前；文本超过规则 `maxLength`（或全局上限）时直接跳过，不跑正则。
  /// 文件类型用 FileManager 判断（会访问磁盘）。
  public static func contentMatches(
    for input: ToolInput,
    entries: [ToolCatalogEntry],
    usage: ToolUsageStats,
    now: Date,
    limit: Int
  ) -> [ToolMatch] {
    contentMatches(
      for: input, entries: entries, usage: usage, now: now, limit: limit,
      isDirectory: ToolContentMatcher.fileSystemIsDirectory)
  }

  /// 同上；`isDirectory` 判断路径是不是目录，只在规则限定了 `fileType` 时调用，每个路径最多调用一次。
  public static func contentMatches(
    for input: ToolInput,
    entries: [ToolCatalogEntry],
    usage: ToolUsageStats,
    now: Date,
    limit: Int,
    isDirectory: (String) -> Bool
  ) -> [ToolMatch] {
    guard limit > 0 else { return [] }
    var matcher = ToolContentMatcher(input: input)
    var scored: [(match: ToolMatch, index: Int)] = []
    for (index, entry) in entries.enumerated() {
      guard let hit = matcher.bestRule(for: entry, isDirectory: isDirectory) else { continue }
      let score = Double(hit.tier.rawValue) * contentTierWidth + frecencyBonus(usage.frecency(entry.id, now: now))
      let reason = ToolMatch.Reason.content(ruleIndex: hit.index, label: hit.label)
      scored.append((ToolMatch(entry: entry, reason: reason, score: score), index))
    }
    return ranked(scored, limit: limit)
  }
}

/// 一次内容匹配的上下文：输入只预处理一次（长度、目录判断、内置工具确认），对所有功能复用。
struct ToolContentMatcher {
  /// 规则等级，数值越大越靠前。
  enum Tier: Int, Comparable {
    case text = 1
    case files = 2
    case regex = 3

    /// 按等级比较。
    static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// 一个功能命中的规则。
  struct Hit: Equatable {
    let tier: Tier
    let index: Int
    let label: String?
  }

  /// 可用于文本规则的输入；为空或超过全局上限时为 nil。
  let text: String?
  /// `text` 的字符数，规则的 `minLength` / `maxLength` 都按字符计。
  let length: Int
  let files: [String]
  private var directoryCache: [String: Bool] = [:]
  private var builtinAcceptance: [ToolBuiltinHandler: Bool] = [:]

  /// 预处理输入：超过全局上限的文本直接视为没有文本。
  init(input: ToolInput) {
    if let text = input.text, !text.isEmpty, text.utf16.count <= ToolMatcher.maximumContentLength {
      self.text = text
      length = text.count
    } else {
      text = nil
      length = 0
    }
    files = input.files
  }

  /// 功能命中的最佳规则；没有命中时为 nil。内置工具还要经过 `BuiltinTextTools.acceptsContent` 二次确认，
  /// 因为它们的正则只是粗筛（例如普通单词也符合 Base64 字符集）。
  mutating func bestRule(for entry: ToolCatalogEntry, isDirectory: (String) -> Bool) -> Hit? {
    var best: Hit?
    for (index, rule) in entry.feature.match.enumerated() {
      let tier = Self.tier(of: rule)
      if let best, best.tier >= tier { continue }
      guard matches(rule, isDirectory: isDirectory) else { continue }
      best = Hit(tier: tier, index: index, label: rule.label)
      if tier == .regex { break }
    }
    guard let best else { return nil }
    if best.tier != .files, entry.source == .builtin, case .builtin(let action) = entry.feature.action,
      !acceptsBuiltin(action.handler)
    {
      return nil
    }
    return best
  }

  /// 规则的等级。
  static func tier(of rule: ToolMatchRule) -> Tier {
    switch rule {
    case .regex: .regex
    case .files: .files
    case .text: .text
    }
  }

  /// 单条规则是否命中。
  private mutating func matches(_ rule: ToolMatchRule, isDirectory: (String) -> Bool) -> Bool {
    switch rule {
    case .regex(let regex):
      guard let text, fits(minimum: regex.minLength, maximum: regex.maxLength),
        let expression = ToolRegex.compiled(regex.pattern)
      else { return false }
      // 校验已保证正则不产生空匹配；这里仍跳过空匹配，代码直接构造的规则也不会命中任意输入。
      return ToolRegex.firstMatch(expression, in: text, allowsEmptyMatch: false) == .matched
    case .text(let rule):
      guard let text, fits(minimum: rule.minLength, maximum: rule.maxLength) else { return false }
      guard let exclude = rule.exclude else { return true }
      // exclude 无法编译或超时都按「排除」处理：宁可少推荐，也不推荐作者明确不想处理的内容。
      guard let expression = ToolRegex.compiled(exclude) else { return false }
      return ToolRegex.firstMatch(expression, in: text, allowsEmptyMatch: true) == .notMatched
    case .files(let rule):
      return matchesFiles(rule, isDirectory: isDirectory)
    }
  }

  /// 文本长度是否在规则范围内（缺省 1 到 10,000 个字符）。
  private func fits(minimum: Int?, maximum: Int?) -> Bool {
    length >= (minimum ?? 1) && length <= (maximum ?? ToolRegexRule.defaultMaxLength)
  }

  /// files 规则：数量在范围内，且每个路径都满足类型、扩展名或文件名正则。
  private mutating func matchesFiles(_ rule: ToolFilesRule, isDirectory: (String) -> Bool) -> Bool {
    guard !files.isEmpty, files.count >= (rule.minCount ?? 1),
      files.count <= (rule.maxCount ?? ToolManifestLimits.fileCount)
    else { return false }
    var expression: NSRegularExpression?
    if let pattern = rule.pattern {
      guard let compiled = ToolRegex.compiled(pattern) else { return false }
      expression = compiled
    }
    for path in files {
      let name = (path as NSString).lastPathComponent
      if let fileType = rule.fileType, (fileType == .directory) != directory(path, isDirectory) { return false }
      if let extensions = rule.extensions {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard extensions.contains(where: { $0.lowercased() == fileExtension }) else { return false }
      }
      if let expression, ToolRegex.firstMatch(expression, in: name, allowsEmptyMatch: true) != .matched {
        return false
      }
    }
    return true
  }

  /// 目录判断，按路径缓存。
  private mutating func directory(_ path: String, _ isDirectory: (String) -> Bool) -> Bool {
    if let cached = directoryCache[path] { return cached }
    let value = isDirectory(path)
    directoryCache[path] = value
    return value
  }

  /// 内置工具对当前文本的二次确认，按处理器缓存。
  private mutating func acceptsBuiltin(_ handler: ToolBuiltinHandler) -> Bool {
    guard let text else { return false }
    if let cached = builtinAcceptance[handler] { return cached }
    let value = BuiltinTextTools.acceptsContent(handler, text: text)
    builtinAcceptance[handler] = value
    return value
  }

  /// 默认的目录判断：路径存在且是目录（跟随符号链接）。
  static func fileSystemIsDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }
}
