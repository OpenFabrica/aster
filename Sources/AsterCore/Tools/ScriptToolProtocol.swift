// 脚本工具协议：stdin 内容、环境变量、list 输出解析、可执行文件解析与各项上限。进程本身由应用层的运行器启动。
import Foundation

/// 脚本工具与 Aster 之间的约定，见 docs/developer/tools-and-plugins.md「脚本工具协议」。
public enum ScriptToolProtocol {
  public static let defaultTimeout: TimeInterval = 10
  public static let listTimeout: TimeInterval = 3
  public static let maximumTimeout: TimeInterval = 60
  /// 超时后先 SIGTERM 进程组，再等这么久 SIGKILL。
  public static let terminationGrace: TimeInterval = 1
  public static let stdoutLimit = 1_048_576
  public static let stderrLimit = 65_536
  /// 失败时界面显示的 stderr 前缀长度（UTF-8 字节）。
  public static let stderrDisplayLimit = 4_096
  public static let listItemLimit = 200
  /// list 项 `title` 的字符上限，超出截断。
  public static let listTitleLimit = 256
  /// list 项 `subtitle` 的字符上限，超出截断。
  public static let listSubtitleLimit = 512
  /// list 项 `value` 的 UTF-8 字节上限，超出整份输出作废。
  public static let listValueLimit = 65_536
  public static let listDebounce: TimeInterval = 0.3
  /// 单个 `ASTER_*` 环境变量值的 UTF-8 字节上限。参数与环境合计受 ARG_MAX（约 1 MiB）限制，
  /// 粘贴的大段查询放进 `ASTER_QUERY` 会让 posix_spawn 以 E2BIG 失败；完整内容始终经 stdin 传递。
  public static let environmentValueLimit = 65_536
  /// 脚本固定使用的 PATH，不继承 Aster 进程环境。
  public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
  /// 从 Aster 进程环境里透传给脚本的变量（PATH 固定为 `defaultPath`）。
  public static let inheritedEnvironmentKeys = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"]
  /// GUI 进程通常没有 LANG；缺省时给 UTF-8，否则脚本里的 Python 等会按 ASCII 读写 stdin/stdout。
  public static let fallbackLanguage = "en_US.UTF-8"

  // MARK: 输入

  /// 按 stdin 模式生成写给脚本的内容。
  /// - `text`：输入文本原文，没有输入时为空。
  /// - `json`：`{"code", "query", "input": {"text", "files", "source"}, "context": {"workingDirectory", "isRemote",
  ///   "locale", "appearance"}}`，键按字母序；缺省值写成 `null` 而不是省略，脚本可以直接按键取值。
  public static func stdinData(code: String, query: String?, input: ToolInput, mode: ToolStdinMode) throws -> Data {
    switch mode {
    case .text:
      return Data((input.text ?? "").utf8)
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(ScriptStdinPayload(code: code, query: query, input: input))
    }
  }

  /// Aster 注入的 `ASTER_*` 变量；`ASTER_QUERY` 与 `ASTER_CWD` 只在有值时出现。
  /// 值里的 NUL 会被去掉（环境变量是 C 字符串），并按 `environmentValueLimit` 截断。
  public static func environment(
    pluginID: String,
    code: String,
    query: String?,
    input: ToolInput,
    pluginDirectory: String,
    dataDirectory: String
  ) -> [String: String] {
    var environment = [
      "ASTER_FEATURE": code,
      "ASTER_PLUGIN_ID": pluginID,
      "ASTER_PLUGIN_DIR": pluginDirectory,
      "ASTER_PLUGIN_DATA": dataDirectory,
      "ASTER_LOCALE": input.context.locale,
    ]
    if let query { environment["ASTER_QUERY"] = query }
    if let cwd = input.context.workingDirectory { environment["ASTER_CWD"] = cwd }
    return environment.mapValues(environmentValue)
  }

  /// 基础环境：固定 PATH，加上从 `processEnvironment` 里挑出的少数变量，不继承其他变量。运行器的完整环境为
  /// `baseEnvironment(from:)` 合并 `environment(...)`（后者优先）。
  public static func baseEnvironment(from processEnvironment: [String: String]) -> [String: String] {
    var environment = ["PATH": defaultPath]
    for key in inheritedEnvironmentKeys {
      if let value = processEnvironment[key], !value.isEmpty { environment[key] = environmentValue(value) }
    }
    if environment["LANG"] == nil { environment["LANG"] = fallbackLanguage }
    return environment
  }

  /// 脚本的工作目录：来源 Pane 的本地目录，否则用户主目录。目录是否还存在由运行器确认。
  public static func workingDirectory(for input: ToolInput, homeDirectory: String) -> String {
    guard !input.context.isRemote, let directory = input.context.workingDirectory, !directory.isEmpty else {
      return homeDirectory
    }
    return directory
  }

  /// 环境变量值：去掉 NUL 并截断。
  static func environmentValue(_ value: String) -> String {
    let cleaned = value.contains("\0") ? value.replacingOccurrences(of: "\0", with: "") : value
    return ToolTextRules.prefix(cleaned, maximumUTF8Bytes: environmentValueLimit)
  }

  // MARK: 输出

  /// 解析 list 模式的 stdout：`{"items": [{"title", "subtitle"?, "value"?, "icon"?}]}`，多余的键忽略。
  /// 超限的处理（取舍：展示字段宽松，数据字段严格）：
  /// - 超过 200 项：只取前 200 项（列表只是展示，后面的项用户本来也看不到）；
  /// - `title` > 256、`subtitle` > 512 个字符：截断并以 `…` 结尾，控制字符与换行换成空格；
  /// - `value` > 64 KiB：整份输出作废并报错。它是要复制或预填的数据，截断会悄悄交出错误内容；
  /// - `title` 为空：整份输出作废并报错。
  /// `title` 被改动且没有 `value` 时，把原始 `title` 存进 `value`，复制出去的仍是脚本给的原文。
  public static func parseList(_ data: Data) throws -> [ToolListItem] {
    guard data.count <= stdoutLimit else { throw ScriptToolError.outputTooLarge }
    let output: ScriptListOutput
    do {
      output = try JSONDecoder().decode(ScriptListOutput.self, from: data)
    } catch {
      throw ScriptToolError.invalidListOutput(L("list 输出必须是 {\"items\": [...]}"))
    }
    var items: [ToolListItem] = []
    items.reserveCapacity(min(output.items.count, listItemLimit))
    for (index, raw) in output.items.prefix(listItemLimit).enumerated() {
      let position = String(index + 1)
      guard !raw.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ScriptToolError.invalidListOutput(L("第 \(position) 项缺少 title"))
      }
      if let value = raw.value, value.utf8.count > listValueLimit {
        throw ScriptToolError.invalidListOutput(L("第 \(position) 项的 value 超过 64 KiB"))
      }
      let title = ToolTextRules.singleLine(raw.title, maximumCharacters: listTitleLimit)
      var value = raw.value
      if value == nil, title != raw.title {
        guard raw.title.utf8.count <= listValueLimit else {
          throw ScriptToolError.invalidListOutput(L("第 \(position) 项的 value 超过 64 KiB"))
        }
        value = raw.title
      }
      let subtitle = raw.subtitle.map { ToolTextRules.singleLine($0, maximumCharacters: listSubtitleLimit) }
      items.append(ToolListItem(title: title, subtitle: subtitle, value: value, icon: raw.icon))
    }
    return items
  }

  /// text 模式：UTF-8 解码（非法字节替换为 U+FFFD），去掉末尾一个换行（`\n` 或 `\r\n`）。
  public static func decodeText(_ data: Data) -> String {
    var text = String(decoding: data, as: UTF8.self)
    // `\r\n` 在 Swift 里是一个 Character，去掉最后一个字符就是去掉整个换行。
    if text.last == "\n" || text.last == "\r\n" { text.removeLast() }
    return text
  }

  /// 失败时给用户看的 stderr：按 UTF-8 解码（非法字节替换），去掉首尾空白，最多 4 KiB（在字符边界截断）。
  public static func stderrSummary(_ data: Data) -> String {
    let text = String(decoding: data.prefix(stderrLimit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return ToolTextRules.prefix(text, maximumUTF8Bytes: stderrDisplayLimit)
  }

  /// `terminal` 输出模式在新终端标签里输入的命令行：每项按 POSIX 单引号转义后以空格连接。
  public static func terminalCommandLine(_ command: [String]) -> String {
    command.map(ShellQuoting.singleQuoted).joined(separator: " ")
  }

  // MARK: 可执行文件

  /// 固定 PATH 拆成的目录列表，裸名命令按这个顺序查找。
  public static var defaultSearchDirectories: [String] {
    defaultPath.split(separator: ":").map(String.init)
  }

  /// 裸名：不含 `/`，只用 `[A-Za-z0-9._+-]`，1–64 个字符，且不是纯点号（`.`、`..`）。
  /// 用来区分「去 PATH 里找解释器」（`python3`）和「插件目录里的脚本」（`bin/run.sh`）。
  public static func isBareCommandName(_ name: String) -> Bool {
    guard (1...64).contains(name.utf8.count), name.contains(where: { $0 != "." }) else { return false }
    return name.unicodeScalars.allSatisfy {
      ToolTextRules.isAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "+" || $0 == "-"
    }
  }

  /// 解析 `command[0]`，三种写法：
  /// - 含 `/` 的相对路径：相对插件目录，解析符号链接后必须仍在插件目录内；
  /// - 绝对路径：原样使用；
  /// - 裸名（`python3`、`node`）：先看插件目录里有没有同名文件，有就按插件目录解析（保持 `run.sh` 这类
  ///   旧写法不变，且不受 PATH 影响）；没有再在 `searchPath` 里逐目录找可执行的普通文件，找不到抛
  ///   `executableNotFound`。不扩 PATH、不读用户 shell 配置，nvm / pyenv 等装的解释器因此找不到。
  /// 目标都必须是可执行的普通文件。`searchPath` 缺省为固定 PATH，测试可以注入。
  public static func resolveExecutable(
    _ command: [String],
    pluginDirectory: URL,
    fileManager: FileManager = .default,
    searchPath: [String] = defaultSearchDirectories
  ) throws -> (executable: URL, arguments: [String]) {
    guard let first = command.first, !first.isEmpty else {
      throw ScriptToolError.invalidCommand(L("命令为空"))
    }
    let executable: URL
    if first.hasPrefix("/") {
      executable = URL(fileURLWithPath: first)
    } else {
      // 先按字面拒绝 `..`，再用 realpath 解析符号链接后比较前缀；两步都要，任何一步越界都拒绝。
      guard !first.split(separator: "/").contains("..") else {
        throw ScriptToolError.invalidCommand(L("命令路径超出插件目录"))
      }
      guard let root = ToolPluginDigest.canonicalPath(pluginDirectory.path) else {
        throw ScriptToolError.invalidCommand(L("插件目录不存在"))
      }
      let candidate = (root as NSString).appendingPathComponent(first)
      // 裸名且插件目录里没有同名条目（含悬空链接）时才去 PATH 找；有同名条目一律走插件目录规则，
      // 这样 `run.sh` 即使 PATH 里也有同名文件，运行的仍是插件自己的。
      if isBareCommandName(first), !fileManager.fileExists(atPath: candidate) {
        let found = try searchExecutable(first, in: searchPath, fileManager: fileManager)
        return (found, Array(command.dropFirst()))
      }
      guard let resolved = ToolPluginDigest.canonicalPath(candidate) else {
        throw ScriptToolError.invalidCommand(L("命令不存在或不可执行"))
      }
      let prefix = root.hasSuffix("/") ? root : root + "/"
      guard resolved.hasPrefix(prefix), resolved.count > prefix.count else {
        throw ScriptToolError.invalidCommand(L("命令路径超出插件目录"))
      }
      executable = URL(fileURLWithPath: resolved)
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue,
      fileManager.isExecutableFile(atPath: executable.path)
    else { throw ScriptToolError.invalidCommand(L("命令不存在或不可执行")) }
    return (executable, Array(command.dropFirst()))
  }

  /// 在目录列表里按顺序找第一个可执行的普通文件；不解析符号链接（Homebrew 的 bin 都是链接，保留原路径）。
  private static func searchExecutable(
    _ name: String,
    in directories: [String],
    fileManager: FileManager
  ) throws -> URL {
    for directory in directories where !directory.isEmpty {
      let path = (directory as NSString).appendingPathComponent(name)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
        fileManager.isExecutableFile(atPath: path)
      {
        return URL(fileURLWithPath: path)
      }
    }
    throw ScriptToolError.executableNotFound(name)
  }
}

/// json 模式的 stdin。手写编码是为了把缺省值写成 `null`，并让 `input` 不带 `context`（它单独放在顶层）。
private struct ScriptStdinPayload: Encodable {
  let code: String
  let query: String?
  let input: ToolInput

  private enum CodingKeys: String, CodingKey {
    case code, query, input, context
  }

  private enum InputKeys: String, CodingKey {
    case text, files, source
  }

  private enum ContextKeys: String, CodingKey {
    case workingDirectory, isRemote, locale, appearance
  }

  /// 按文档结构写出，可选值写 `null`。
  func encode(to encoder: any Encoder) throws {
    var root = encoder.container(keyedBy: CodingKeys.self)
    try root.encode(code, forKey: .code)
    try root.encode(query, forKey: .query)
    var inputValues = root.nestedContainer(keyedBy: InputKeys.self, forKey: .input)
    try inputValues.encode(input.text, forKey: .text)
    try inputValues.encode(input.files, forKey: .files)
    try inputValues.encode(input.source, forKey: .source)
    var context = root.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
    try context.encode(input.context.workingDirectory, forKey: .workingDirectory)
    try context.encode(input.context.isRemote, forKey: .isRemote)
    try context.encode(input.context.locale, forKey: .locale)
    try context.encode(input.context.appearance, forKey: .appearance)
  }
}

/// list 模式 stdout 的外层结构。
private struct ScriptListOutput: Decodable {
  let items: [ScriptListItem]
}

/// list 模式的原始一项，校验与截断前。
private struct ScriptListItem: Decodable {
  let title: String
  let subtitle: String?
  let value: String?
  let icon: String?
}

/// list 模式的一项。
public struct ToolListItem: Codable, Equatable, Sendable {
  public var title: String
  public var subtitle: String?
  /// 复制或预填的内容；缺省用标题。
  public var value: String?
  public var icon: String?

  /// 逐字段构造；`value` 缺省时复制标题。
  public init(title: String, subtitle: String? = nil, value: String? = nil, icon: String? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.value = value
    self.icon = icon
  }

  /// 实际复制或预填的内容。
  public var resolvedValue: String { value ?? title }
}

/// 脚本工具的失败原因。
public enum ScriptToolError: Error, Equatable, Sendable {
  case invalidCommand(String)
  case invalidListOutput(String)
  case outputTooLarge
  case timedOut
  case cancelled
  case exitStatus(Int32, stderr: String)
  case launchFailed(String)
  /// 裸名命令在固定 PATH 里找不到（参数是命令名）。
  case executableNotFound(String)

  /// 给用户看的说明。插值都转成 String，保证本地化表的 key 是 `%@`。
  public var localizedMessage: String {
    switch self {
    case .invalidCommand(let reason): L("命令无效：\(reason)")
    case .invalidListOutput(let reason): L("输出格式不对：\(reason)")
    case .outputTooLarge: L("输出太大，已停止")
    case .timedOut: L("运行超时，已停止")
    case .cancelled: L("已取消")
    case .exitStatus(let status, let stderr):
      stderr.isEmpty ? L("退出码 \(String(status))") : L("退出码 \(String(status))：\(stderr)")
    case .launchFailed(let reason): L("无法启动：\(reason)")
    case .executableNotFound(let name): L("PATH 里没有 \(name)")
    }
  }
}
