// 将规格、学习和环境快照合成为可追加的候选。
import Foundation

/// 补全查询的命令段。只分析文本，不进行 Shell 展开或执行。
public struct CompletionInput: Equatable, Sendable {
  public let line: String
  public let segment: String
  public let segmentStart: Int
  public let parsed: ShellCommandTokenization

  public init(_ line: String) {
    self.line = line
    var quote: Character?
    var escaped = false
    var start = 0
    let characters = Array(line)
    for (offset, character) in characters.enumerated() {
      if escaped { escaped = false; continue }
      if character == "\\", quote != "'" { escaped = true; continue }
      if let active = quote {
        if character == active { quote = nil }
      } else if character == "'" || character == "\"" {
        quote = character
      } else if "|;&\n".contains(character) {
        start = offset + 1
      }
    }
    while start < characters.count, characters[start].isWhitespace { start += 1 }
    segmentStart = start
    segment = String(line.dropFirst(start))
    parsed = ShellCommandTokenizer.tokenize(segment)
  }
}

/// 根据规格、目录学习、词频以及只读环境快照生成候选。
/// 排序与来源合成集中在此处，终端只负责显示、选择和发送追加字节。
public struct CommandCompletionEngine: Sendable {
  public let specifications: AutocompleteSpecDatabase

  public init(specifications: AutocompleteSpecDatabase) {
    self.specifications = specifications
  }

  public func complete(
    line: String, directory: String, learning: CompletionLearningState,
    aliases: [String] = [], seenTokens: Set<String> = [], executables: AutocompleteExecutableIndex = .empty,
    readme: [String] = [], files: [AutocompleteCandidate] = [],
    dynamic: [CompletionDynamicItem] = [],
    language: AutocompleteDescriptionLanguage = .english, now: Date = Date()
  ) -> AutocompleteResult {
    guard line.utf8.count <= 4_096,
      !line.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x1b })
    else { return .empty }
    let input = CompletionInput(line)
    let parsed = input.parsed
    guard !parsed.tokens.isEmpty else { return .empty }
    let token = parsed.currentToken
    let start = input.segmentStart + parsed.currentTokenStart
    let commandName = parsed.tokens.first ?? ""
    let isCommandPosition = parsed.tokens.count == 1 && !token.isEmpty
    let hasSpecContext = (parsed.tokens.count > 1 || token.isEmpty)
      && specifications.command(named: commandName) != nil
    let historyContext = CompletionHistoryContext.resolve(tokens: parsed.tokens, database: specifications)
    let context = isCommandPosition ? "" : historyContext.context
    var other: [AutocompleteCandidate] = []
    var history: [AutocompleteCandidate] = []

    let historyPrefix = line.utf8.map(Self.lowerASCIIByte)
    let matchingLines = learning.fullLines.filter {
      $0.directory == directory && $0.command.utf8.lazy.map(Self.lowerASCIIByte).starts(with: historyPrefix)
    }.sorted { $0.lastUsed > $1.lastUsed }.prefix(500)
    for entry in matchingLines {
      history.append(AutocompleteCandidate(
        insertText: entry.command, kind: .learnedCommand,
        score: CompletionLearningState.frecency(score: entry.score, lastUsed: entry.lastUsed, now: now),
        isLearned: true, historyUsage: .init(useCount: entry.count, lastUsedAt: entry.lastUsed)))
    }
    for entry in learning.learnedFolder where entry.directory == directory
      && entry.command.hasPrefix(line) && entry.command != line
    {
      other.append(AutocompleteCandidate(insertText: entry.command, kind: .snippet, score: 0))
    }
    for value in readme where value.hasPrefix(line) && value != line {
      other.append(AutocompleteCandidate(insertText: value, kind: .readmeCommand, score: 0))
    }

    func add(_ value: String, description: String = "", kind: AutocompleteCandidateKind,
      at offset: Int = start, typed: String = token, score: Double = 0, learned: Bool = false,
      displayText: String? = nil, clearLeader: Bool = false)
    {
      guard value != typed, FigCompletionRules.matches(value, prefix: typed) else { return }
      // 原版普通候选保持字面文本；接受时删除当前原始token再写入，不靠只追加前缀。
      // 路径仍为预览生成可追加编码，真正接受由 CompletionAcceptance 按原生规则编码。
      let insertion = kind == .file || kind == .folder
        ? AutocompleteShellInsertion.token(value: value, typed: typed,
          raw: String(line.dropFirst(offset)), closeQuote: kind != .folder) ?? value
        : value
      let stem = value.last == "/" || value.last == "\\" ? String(value.dropLast()) : value
      let usage = learning.history.filter { $0.command == context && ($0.token == value || $0.token == stem) }
      let historyScore = usage.map {
        CompletionLearningState.frecency(score: $0.score, lastUsed: $0.lastUsed, now: now)
          + (seenTokens.contains(context + "\t" + $0.token) ? 10 : 0)
      }.max()
      other.append(AutocompleteCandidate(
        insertText: insertion, displayText: displayText ?? value, description: description, kind: kind,
        score: historyScore ?? score, historyScore: historyScore, clearLeader: clearLeader,
        replacement: .currentToken(start: offset), isLearned: learned))
    }

    if !input.segment.isEmpty, parsed.tokens.count <= 1, !token.isEmpty {
      for spec in specifications.commands where !spec.aliases.contains("hidden") {
        add(spec.name, description: spec.description.text(for: language), kind: .command)
      }
      for name in aliases { add(name, kind: .alias) }
      for name in executables.names(withPrefix: token) { add(name, kind: .command) }
    } else if let root = specifications.command(named: commandName) {
      let completed = token.isEmpty
        ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())
      let context = FigCompletionContext(root: root, completed: completed)
      if token.hasPrefix("-") {
        for option in FigCompletionRules.options(
          of: context.command, ancestors: context.ancestors, prefix: token)
        {
          add(option.name, description: option.description, kind: .option)
        }
      } else {
        if context.positionalCount == 0 {
          for child in FigCompletionRules.subcommands(of: context.command, prefix: token) {
            add(child.name, description: child.description.text(for: language), kind: .subcommand)
          }
        }
        for item in FigCompletionRules.suggestions(of: context.command, prefix: token) {
          add(item.name, description: item.description, kind: .argument)
        }
      }
    }
    // 原生动态分派与静态 Fig 字段是独立来源；结果已经由后台查询限定命令和目录。
    for item in dynamic {
      add(item.name, description: item.description, kind: item.kind,
        displayText: item.displayText, clearLeader: item.clearLeader)
    }
    if !isCommandPosition && !hasSpecContext {
      for entry in learning.history where entry.command == context {
        add(entry.token, kind: .argument, learned: true)
      }
    }
    // 文件适配器已经处理引号与目录后缀；不二次转义这些字节。
    other += files.map { candidate in
      let stem = candidate.displayText.last == "/" ? String(candidate.displayText.dropLast()) : candidate.displayText
      let score = learning.history.filter { $0.command == context && ($0.token == candidate.displayText || $0.token == stem) }.map {
        CompletionLearningState.frecency(score: $0.score, lastUsed: $0.lastUsed, now: now)
          + (seenTokens.contains(context + "\t" + $0.token) ? 10 : 0)
      }.max()
      return AutocompleteCandidate(insertText: candidate.insertText, displayText: candidate.displayText,
        description: candidate.description, kind: candidate.kind, score: score ?? 0,
        historyScore: score, clearLeader: false, replacement: candidate.replacement)
    }
    let newestHistoryDate = matchingLines.map(\.lastUsed).max()
    history = Array(Self.sortedUnique(history, line: line, includeExact: true).prefix(20))
    let historyLeads: Bool
    if let first = history.first, first.insertText != line {
      historyLeads = history.count == 1 || (first.score >= history[1].score + 0.5
        && first.historyUsage?.lastUsedAt == newestHistoryDate)
    } else {
      historyLeads = false
    }
    // exact 会先参与限额和领先判断，再移除，不能移除后重新挑选“领先”首项。
    history.removeAll { $0.insertText == line }
    history = history.enumerated().map { $0.element.withClearLeader($0.offset == 0 && historyLeads) }
    other = Self.sortedUnique(other, line: line, specificationOrder: hasSpecContext)
    // known-spec 排序保留来源的 clear_leader；静态候选为 false，动态值不能覆盖。
    let rankedScores = other.compactMap(\.historyScore)
    let otherLeads = !isCommandPosition && !hasSpecContext && other.first?.historyScore != nil
      && (rankedScores.count == 1 || (rankedScores.count > 1 && rankedScores[0] >= rankedScores[1] * 1.5))
    if !hasSpecContext {
      other = other.enumerated().map { $0.element.withClearLeader($0.offset == 0 && otherLeads) }
    }
    let remembered = Set(history.map(\.insertText))
    other.removeAll { remembered.contains($0.resultingLine(from: line) ?? "") }
    // 原版先计算目录整行历史，去除非历史重复项；非历史的明确首项可以插到历史之前。
    let result: [AutocompleteCandidate]
    if !history.isEmpty, CompletionPresentation.leaderIsClear(history) || !CompletionPresentation.leaderIsClear(other) {
      result = history + other
    } else if let leader = other.first {
      result = [leader] + history + other.dropFirst()
    } else {
      result = history
    }
    return .make(candidates: Array(result.prefix(200)), line: line)
  }

  private static func sortedUnique(
    _ candidates: [AutocompleteCandidate], line: String, specificationOrder: Bool = false,
    includeExact: Bool = false
  ) -> [AutocompleteCandidate] {
    var seen: Set<String> = []
    return candidates.enumerated().sorted {
      if specificationOrder, ($0.element.historyScore != nil) != ($1.element.historyScore != nil) {
        return $0.element.historyScore != nil
      }
      if $0.element.score != $1.element.score { return $0.element.score > $1.element.score }
      if let left = $0.element.historyUsage?.lastUsedAt,
        let right = $1.element.historyUsage?.lastUsedAt, left != right { return left > right }
      if specificationOrder, kindRank($0.element.kind) != kindRank($1.element.kind) {
        return kindRank($0.element.kind) < kindRank($1.element.kind)
      }
      return $0.offset < $1.offset
    }.map(\.element).filter {
      // SQLite LIKE 的 ASCII 大小写匹配可能产生无法只追加的整行；保留查询结果，
      // 终端接受适配器仍负责拒绝它不能安全执行的替换。
      let offset = $0.replacement.start
      let value = includeExact ? $0.insertText
        : (offset >= 0 && offset <= line.count ? String(line.prefix(offset)) + $0.insertText : nil)
      guard let value, includeExact || value != line else { return false }
      return seen.insert(value).inserted
    }
  }

  private static func lowerASCIIByte(_ byte: UInt8) -> UInt8 {
    (65...90).contains(byte) ? byte + 32 : byte
  }

  private static func kindRank(_ kind: AutocompleteCandidateKind) -> Int {
    switch kind {
    case .subcommand, .alias, .command: 0
    case .argument, .dynamicArgument: 1
    case .option: 2
    case .file, .folder: 3
    default: 4
    }
  }
}
