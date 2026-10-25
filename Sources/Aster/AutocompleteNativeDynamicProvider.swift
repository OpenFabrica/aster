// Otty 固定动态分派器的应用层实现；所有磁盘和进程操作在可取消的后台任务内。
import AsterCore
import Darwin
import Foundation

struct AutocompleteNativeDynamicProvider: Sendable {
  let environment: [String: String]
  var totalTimeout: TimeInterval = 3
  var commandTimeout: TimeInterval = 2
  var maximumFileBytes = 1_048_576
  var additionalSSHConfigPaths: [URL] = []
  var recentSSHHosts: [String] = []

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  /// 输入行只做分词，不执行其中的表达式。各来源失败返回空来源；取消丢弃整个查询。
  /// specifications 用于恢复已识别子命令链和参数位置；不执行规格中的 script。
  func candidates(line: String, directory: String, executables: [String],
    aliases: [String: String] = [:], specifications: AutocompleteSpecDatabase? = nil
  ) async -> [CompletionDynamicItem] {
    guard !Task.isCancelled else { return [] }
    let task = Task.detached(priority: .userInitiated) {
      query(line: line, directory: directory, executables: executables,
        aliases: aliases, specifications: specifications)
    }
    return await withTaskCancellationHandler {
      let items = await task.value
      return Task.isCancelled ? [] : items
    } onCancel: { task.cancel() }
  }

  private func query(line: String, directory: String, executables: [String],
    aliases: [String: String], specifications: AutocompleteSpecDatabase?
  ) -> [CompletionDynamicItem] {
    let context = AutocompleteDynamicContext(line: line, directory: directory,
      aliases: aliases, specifications: specifications,
      deadline: ContinuousClock.now.advanced(by: .seconds(totalTimeout)))
    guard context.hasTime else { return [] }
    switch context.root {
    case "git":
      let process = AutocompleteDynamicProcess(environment: environment)
      var items: [CompletionDynamicItem] = []
      for source in AutocompleteGitDynamic.sources(context: context) {
        guard context.hasTime else { break }
        let time = min(commandTimeout, context.remainingTime)
        if let output = process.run(arguments: source.arguments, directory: directory, timeout: time) {
          items += AutocompleteGitDynamic.parse(output, source: source)
        }
      }
      return Task.isCancelled ? [] : items
    case "which", "whence", "type", "command":
      guard context.argumentPosition == 0 else { return [] }
      return executables.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        .map { CompletionDynamicItem(name: $0, kind: .argument) }
    case "npm", "npx", "pnpm", "yarn", "bun", "bunx":
      return packageItems(context: context)
    case "make", "gmake":
      return makeItems(context: context)
    case "docker", "docker-compose":
      return composeItems(context: context)
    case "cargo":
      return cargoItems(context: context)
    case "ssh", "scp", "sftp":
      return sshItems(context: context)
    default:
      return []
    }
  }

  func text(at url: URL) -> String? {
    guard !Task.isCancelled, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
      let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximumFileBytes + 1),
      data.count <= maximumFileBytes else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 原版先限制成功读取的目录条目数，再检查 UTF-8、隐藏名和前缀。
  /// 用逐项读取保持 200 条预算，避免大型 node_modules 先被完整枚举。
  func directoryNames(at url: URL, context: AutocompleteDynamicContext) -> [String] {
    guard context.hasTime, let directory = opendir(url.path) else { return [] }
    defer { closedir(directory) }
    var names: [String] = []
    var visited = 0
    while visited < 200, context.hasTime, let entry = readdir(directory) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
      }
      if name == "." || name == ".." { continue }
      visited += 1
      if let name { names.append(name) }
    }
    return names
  }
}

/// arg_position 与原生 GeneratorContext 一致：只排除前导 '-' 的已完成参数。
struct AutocompleteDynamicContext: Sendable {
  let root: String
  let tokens: [String]
  let currentToken: String
  let directory: String
  let commandPath: [String]
  let deadline: ContinuousClock.Instant

  init(line: String, directory: String, aliases: [String: String] = [:],
    specifications: AutocompleteSpecDatabase? = nil, deadline: ContinuousClock.Instant
  ) {
    let parsed = ShellCommandTokenizer.tokenize(line)
    tokens = parsed.tokens
    currentToken = parsed.currentToken
    self.directory = directory
    self.deadline = deadline
    let original = tokens.first ?? ""
    let supported: Set<String> = ["git", "npm", "npx", "pnpm", "yarn", "bun", "bunx",
      "make", "gmake", "docker", "docker-compose", "cargo", "ssh", "scp", "sftp",
      "which", "whence", "type", "command", "jump"]
    root = supported.contains(original) ? original : aliases[original] ?? original
    let completed = currentToken.isEmpty ? tokens.count : max(0, tokens.count - 1)
    if let spec = specifications?.command(named: root) {
      commandPath = Array(FigCompletionContext(root: spec,
        completed: Array(tokens.dropFirst().prefix(max(0, completed - 1)))).commandPath.dropFirst())
    } else {
      commandPath = []
    }
  }

  var argumentPosition: Int {
    let end = currentToken.isEmpty ? tokens.count : max(0, tokens.count - 1)
    let start = commandPath.count + 1
    guard start < end else { return 0 }
    return tokens[start..<end].filter { !$0.hasPrefix("-") }.count
  }

  var previousToken: String? {
    let index = tokens.count - (currentToken.isEmpty ? 1 : 2)
    return index >= 0 ? tokens[index] : nil
  }

  var hasTime: Bool { !Task.isCancelled && ContinuousClock.now < deadline }
  var remainingTime: TimeInterval {
    let duration = ContinuousClock.now.duration(to: deadline).components
    return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
  }
  func hasFlag(_ values: [String]) -> Bool { tokens.contains { values.contains($0) } }
}
