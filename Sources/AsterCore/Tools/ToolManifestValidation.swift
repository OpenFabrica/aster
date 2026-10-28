// 清单取值校验：逐条实现 docs/developer/tools-and-plugins.md「插件包与清单 v1」的规则，错误指出字段路径。
import Foundation

extension ToolManifest {
  /// 校验字段取值与组合规则。模型可以来自 `decode`，也可以由代码构造（内置清单），规则相同。
  public func validate(source: ToolPluginSource) throws {
    try ToolManifestValidator(manifest: self, source: source).validate()
  }
}

/// 清单各字段的上限。长度未注明「字节」的都按字符（`Character`）计。
enum ToolManifestLimits {
  static let idBytes = 128
  static let nameCharacters = 64
  static let versionCharacters = 32
  static let descriptionCharacters = 512
  static let authorCharacters = 128
  static let homepageCharacters = 512
  static let pathCharacters = 256
  static let networkDomains = 16
  static let features = 32
  static let titleCharacters = 64
  static let subtitleCharacters = 128
  static let keywords = 8
  static let keywordCharacters = 32
  static let matchRules = 8
  static let labelCharacters = 64
  static let patternCharacters = 512
  static let textLength = 1_048_576
  static let extensions = 16
  static let fileCount = 100
  static let commandItems = 32
  static let commandItemBytes = 4_096
  static let timeout: ClosedRange<Double> = 1...60
  static let iconExtensions: Set<String> = ["svg", "png", "jpg", "jpeg", "pdf"]
}

/// 一次校验：按文档顺序检查，遇到第一处问题即抛出。
struct ToolManifestValidator {
  typealias Limits = ToolManifestLimits
  let manifest: ToolManifest
  let source: ToolPluginSource

  /// 入口：顶层字段 → 界面 → 权限与域名 → 功能。
  func validate() throws {
    guard manifest.schemaVersion == ToolManifest.currentSchemaVersion else {
      throw failure("schemaVersion", L("不支持的清单版本"))
    }
    try validateID()
    try requiredText(manifest.name, field: "name", maximum: Limits.nameCharacters)
    try validateVersion()
    try optionalText(manifest.description, field: "description", maximum: Limits.descriptionCharacters)
    try optionalText(manifest.author, field: "author", maximum: Limits.authorCharacters)
    try validateHomepage()
    if let icon = manifest.icon { try iconPath(icon, field: "icon") }
    if let ui = manifest.ui { try validateUI(ui) }
    try validatePermissions()
    try validateNetwork()
    try validateFeatures()
    try validateContributes()
  }

  // MARK: 顶层字段

  /// id 格式、长度，以及 `aster.` 前缀只给内置来源。
  private func validateID() throws {
    guard manifest.id.utf8.count <= Limits.idBytes else {
      throw failure("id", L("不能超过 \(String(Limits.idBytes)) 字节"))
    }
    guard Self.isValidPluginID(manifest.id) else {
      throw failure("id", L("id 格式不对，应形如 com.example.tool"))
    }
    if manifest.id.hasPrefix(ToolManifest.builtinIDPrefix), source != .builtin {
      throw failure("id", L("aster. 前缀保留给内置插件"))
    }
  }

  /// 语义化版本号，≤ 32 个字符。
  private func validateVersion() throws {
    guard manifest.version.count <= Limits.versionCharacters else {
      throw failure("version", L("不能超过 \(String(Limits.versionCharacters)) 个字符"))
    }
    guard Self.isValidVersion(manifest.version) else {
      throw failure("version", L("版本号格式不对，应形如 1.2.0"))
    }
  }

  /// 主页只接受带主机的 `https://` 地址。空白单独拒绝：新系统的 URLComponents 会自动编码空格而不是返回 nil。
  private func validateHomepage() throws {
    guard let homepage = manifest.homepage else { return }
    try optionalText(homepage, field: "homepage", maximum: Limits.homepageCharacters)
    guard homepage.lowercased().hasPrefix("https://"), !homepage.contains(where: \.isWhitespace),
      let components = URLComponents(string: homepage), let host = components.host, !host.isEmpty
    else { throw failure("homepage", L("主页必须是 https:// 地址")) }
  }

  /// 网页入口与默认高度。
  private func validateUI(_ ui: ToolUIConfig) throws {
    try relativePath(ui.main, field: "ui.main")
    guard ui.main.lowercased().hasSuffix(".html") else {
      throw failure("ui.main", L("入口必须是 .html 文件"))
    }
    if let height = ui.height, !ToolUIConfig.heightRange.contains(height) {
      throw failure("ui.height", rangeReason(ToolUIConfig.heightRange))
    }
  }

  /// 权限不能重复（未知权限在解码阶段已拒绝）。
  private func validatePermissions() throws {
    var seen = Set<ToolPermission>()
    for (index, permission) in manifest.permissions.enumerated() where !seen.insert(permission).inserted {
      throw failure("permissions[\(index)]", L("权限重复"))
    }
  }

  /// 声明 network 权限时必须列出 1–16 个域名；没声明时不能列。
  private func validateNetwork() throws {
    guard manifest.permissions.contains(.network) else {
      guard manifest.network.isEmpty else { throw failure("network", L("没有声明 network 权限时不能列出域名")) }
      return
    }
    guard !manifest.network.isEmpty else {
      throw failure("network", L("声明了 network 权限时必须列出允许访问的域名"))
    }
    guard manifest.network.count <= Limits.networkDomains else {
      throw failure("network", countReason(Limits.networkDomains))
    }
    for (index, host) in manifest.network.enumerated() where !ToolTextRules.isValidHostPattern(host) {
      throw failure("network[\(index)]", L("域名必须是小写主机名或 *.主机名，不含协议、端口和路径"))
    }
  }

  // MARK: 功能

  /// 功能数量、代码唯一，以及每个功能自身的字段。`features` 可以缺省，但功能与视图至少要有一个。
  private func validateFeatures() throws {
    guard !manifest.features.isEmpty || !manifest.views.isEmpty else {
      throw failure("features", L("至少需要一个功能或一个视图"))
    }
    guard manifest.features.count <= Limits.features else {
      throw failure("features", countReason(Limits.features))
    }
    var codes = Set<String>()
    for (index, feature) in manifest.features.enumerated() {
      let path = "features[\(index)]"
      guard Self.isValidCode(feature.code) else {
        throw failure("\(path).code", L("功能代码只能用小写字母、数字、- 和 _，以字母或数字开头，最长 32 个字符"))
      }
      guard codes.insert(feature.code).inserted else { throw failure("\(path).code", L("功能代码重复")) }
      try validateFeature(feature, path: path)
    }
  }

  /// 单个功能：标题、副标题、图标、关键词、match 规则与动作。
  private func validateFeature(_ feature: ToolFeature, path: String) throws {
    try requiredText(feature.title, field: "\(path).title", maximum: Limits.titleCharacters)
    try optionalText(feature.subtitle, field: "\(path).subtitle", maximum: Limits.subtitleCharacters)
    if let icon = feature.icon { try iconPath(icon, field: "\(path).icon") }
    guard feature.keywords.count <= Limits.keywords else {
      throw failure("\(path).keywords", countReason(Limits.keywords))
    }
    for (index, keyword) in feature.keywords.enumerated() {
      try requiredText(keyword, field: "\(path).keywords[\(index)]", maximum: Limits.keywordCharacters)
    }
    guard feature.match.count <= Limits.matchRules else {
      throw failure("\(path).match", countReason(Limits.matchRules))
    }
    for (index, rule) in feature.match.enumerated() {
      try validateRule(rule, path: "\(path).match[\(index)]")
    }
    guard !feature.keywords.isEmpty || !feature.match.isEmpty else {
      throw failure(path, L("至少需要一个关键词或一条 match 规则"))
    }
    try validateAction(feature.action, path: "\(path).action")
  }

  /// match 规则：标签与各类型自己的约束。
  private func validateRule(_ rule: ToolMatchRule, path: String) throws {
    try optionalText(rule.label, field: "\(path).label", maximum: Limits.labelCharacters)
    switch rule {
    case .regex(let regex):
      try pattern(regex.pattern, field: "\(path).pattern", allowsEmptyMatch: false)
      try lengths(minimum: regex.minLength, maximum: regex.maxLength, path: path)
    case .text(let text):
      if let exclude = text.exclude { try pattern(exclude, field: "\(path).exclude", allowsEmptyMatch: true) }
      try lengths(minimum: text.minLength, maximum: text.maxLength, path: path)
    case .files(let files):
      try validateFilesRule(files, path: path)
    }
  }

  /// files 规则：扩展名与 pattern 二选一，数量范围合法。
  private func validateFilesRule(_ rule: ToolFilesRule, path: String) throws {
    if rule.extensions != nil, rule.pattern != nil {
      throw failure(path, L("extensions 与 pattern 只能二选一"))
    }
    if let extensions = rule.extensions {
      guard !extensions.isEmpty else { throw failure("\(path).extensions", L("不能为空")) }
      guard extensions.count <= Limits.extensions else {
        throw failure("\(path).extensions", countReason(Limits.extensions))
      }
      for (index, fileExtension) in extensions.enumerated() where !Self.isValidExtension(fileExtension) {
        throw failure("\(path).extensions[\(index)]", L("扩展名必须是小写且不带点"))
      }
    }
    if let pattern = rule.pattern { try self.pattern(pattern, field: "\(path).pattern", allowsEmptyMatch: true) }
    if let minimum = rule.minCount, minimum < 1 { throw failure("\(path).minCount", L("不能小于 1")) }
    if let maximum = rule.maxCount, !(1...Limits.fileCount).contains(maximum) {
      throw failure("\(path).maxCount", rangeReason(1...Limits.fileCount))
    }
    guard (rule.minCount ?? 1) <= (rule.maxCount ?? Limits.fileCount) else {
      throw failure("\(path).minCount", L("不能大于 maxCount（缺省为 100）"))
    }
  }

  /// 动作与清单其余部分的组合规则。
  private func validateAction(_ action: ToolAction, path: String) throws {
    switch action {
    case .ui:
      guard manifest.ui != nil else { throw failure(path, L("网页动作需要清单里的 ui 字段")) }
    case .script(let script):
      guard manifest.permissions.contains(.exec) else { throw failure(path, L("脚本动作需要声明 exec 权限")) }
      try validateCommand(script.command, path: "\(path).command")
      if let timeout = script.timeout, !Limits.timeout.contains(timeout) {
        throw failure("\(path).timeout", L("必须在 1 到 60 秒之间"))
      }
    case .builtin:
      guard source == .builtin else { throw failure(path, L("只有内置插件可以使用 builtin 动作")) }
    }
  }

  /// 命令 1–32 项、每项 ≤ 4096 字节且不含控制字符；相对的 `command[0]` 还要符合插件内路径规则。
  /// 控制字符一律拒绝：`terminal` 输出模式会把命令输入终端，ESC、Ctrl-C 之类会被终端解释。
  func validateCommand(_ command: [String], path: String) throws {
    guard let executable = command.first else { throw failure(path, L("不能为空")) }
    guard command.count <= Limits.commandItems else { throw failure(path, countReason(Limits.commandItems)) }
    for (index, item) in command.enumerated() {
      guard item.utf8.count <= Limits.commandItemBytes else {
        throw failure("\(path)[\(index)]", L("不能超过 \(String(Limits.commandItemBytes)) 字节"))
      }
      guard !ToolTextRules.containsControlCharacters(item) else {
        throw failure("\(path)[\(index)]", L("不能包含控制字符"))
      }
    }
    guard !executable.isEmpty else { throw failure("\(path)[0]", L("不能为空")) }
    if !executable.hasPrefix("/") { try relativePath(executable, field: "\(path)[0]") }
  }

  // MARK: 通用字段规则

  /// 必填文本：去掉首尾空白后不能为空，再按可选文本检查。
  func requiredText(_ value: String, field: String, maximum: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure(field, L("不能为空")) }
    try optionalText(value, field: field, maximum: maximum)
  }

  /// 可选文本：字符数不超过上限，不含控制字符。
  private func optionalText(_ value: String?, field: String, maximum: Int) throws {
    guard let value else { return }
    guard value.count <= maximum else { throw failure(field, L("不能超过 \(String(maximum)) 个字符")) }
    guard !ToolTextRules.containsControlCharacters(value) else { throw failure(field, L("不能包含控制字符")) }
  }

  /// 插件内的相对路径：非空、不以 / 开头、没有 .. 段、不含控制字符、≤ 256 个字符。
  func relativePath(_ path: String, field: String) throws {
    guard !path.isEmpty else { throw failure(field, L("不能为空")) }
    guard !path.hasPrefix("/") else { throw failure(field, L("必须是插件目录内的相对路径")) }
    guard !path.split(separator: "/").contains("..") else { throw failure(field, L("路径不能包含 .. 段")) }
    guard path.count <= Limits.pathCharacters else {
      throw failure(field, L("不能超过 \(String(Limits.pathCharacters)) 个字符"))
    }
    guard !ToolTextRules.containsControlCharacters(path) else { throw failure(field, L("不能包含控制字符")) }
  }

  /// 图标路径：相对路径规则 + 扩展名白名单（大小写无关）。
  func iconPath(_ path: String, field: String) throws {
    try relativePath(path, field: field)
    guard Limits.iconExtensions.contains((path as NSString).pathExtension.lowercased()) else {
      throw failure(field, L("图标只支持 svg、png、jpg、jpeg、pdf"))
    }
  }

  /// 正则：非空、≤ 512 个字符、能编译；`allowsEmptyMatch` 为 false 时不能产生空匹配。
  private func pattern(_ pattern: String, field: String, allowsEmptyMatch: Bool) throws {
    guard !pattern.isEmpty else { throw failure(field, L("不能为空")) }
    guard pattern.count <= Limits.patternCharacters else {
      throw failure(field, L("不能超过 \(String(Limits.patternCharacters)) 个字符"))
    }
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(pattern: pattern)
    } catch {
      throw failure(field, L("正则无法编译"))
    }
    if !allowsEmptyMatch, ToolRegex.canMatchEmpty(expression) {
      throw failure(field, L("正则不能匹配空字符串"))
    }
  }

  /// 文本长度范围：`minLength` ≥ 1，`maxLength` 在 1–1,048,576，且 min ≤ max（缺省 1 与 10,000）。
  private func lengths(minimum: Int?, maximum: Int?, path: String) throws {
    if let minimum, minimum < 1 { throw failure("\(path).minLength", L("不能小于 1")) }
    if let maximum, !(1...Limits.textLength).contains(maximum) {
      throw failure("\(path).maxLength", rangeReason(1...Limits.textLength))
    }
    guard (minimum ?? 1) <= (maximum ?? ToolRegexRule.defaultMaxLength) else {
      throw failure("\(path).minLength", L("不能大于 maxLength（缺省为 10000）"))
    }
  }

  /// 统一构造错误。
  func failure(_ field: String, _ reason: String) -> ToolManifestError {
    ToolManifestError(field: field, reason: reason)
  }

  /// 「最多 N 项」。
  func countReason(_ limit: Int) -> String {
    L("最多 \(String(limit)) 项")
  }

  /// 「必须在 A 到 B 之间」。
  func rangeReason(_ range: ClosedRange<Int>) -> String {
    L("必须在 \(String(range.lowerBound)) 到 \(String(range.upperBound)) 之间")
  }

  // MARK: 格式判断（数字与字母只认 ASCII）

  /// `^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$`
  static func isValidPluginID(_ id: String) -> Bool {
    let segments = id.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count >= 2 else { return false }
    for (index, segment) in segments.enumerated() {
      guard let first = segment.unicodeScalars.first, ToolTextRules.isLowerAlphanumeric(first) else { return false }
      let allowsHyphen = index > 0
      let rest = segment.unicodeScalars.dropFirst()
      guard rest.allSatisfy({ ToolTextRules.isLowerAlphanumeric($0) || (allowsHyphen && $0 == "-") }) else {
        return false
      }
    }
    return true
  }

  /// `^[a-z0-9][a-z0-9_-]{0,31}$`
  static func isValidCode(_ code: String) -> Bool {
    let scalars = code.unicodeScalars
    guard let first = scalars.first, ToolTextRules.isLowerAlphanumeric(first), scalars.count <= 32 else {
      return false
    }
    return scalars.dropFirst().allSatisfy { ToolTextRules.isLowerAlphanumeric($0) || $0 == "_" || $0 == "-" }
  }

  /// `^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$`
  static func isValidVersion(_ version: String) -> Bool {
    let scalars = Array(version.unicodeScalars)
    var index = 0
    for part in 0..<3 {
      let start = index
      while index < scalars.count, ToolTextRules.isDigit(scalars[index]) { index += 1 }
      guard index > start else { return false }
      if part < 2 {
        guard index < scalars.count, scalars[index] == "." else { return false }
        index += 1
      }
    }
    guard index < scalars.count else { return true }
    guard scalars[index] == "-" || scalars[index] == "+" else { return false }
    let suffix = scalars[(index + 1)...]
    return !suffix.isEmpty && suffix.allSatisfy { ToolTextRules.isAlphanumeric($0) || $0 == "." || $0 == "-" }
  }

  /// 文件扩展名：非空、全小写、不含点、斜杠、空白与控制字符。
  static func isValidExtension(_ fileExtension: String) -> Bool {
    !fileExtension.isEmpty && fileExtension == fileExtension.lowercased()
      && !fileExtension.unicodeScalars.contains {
        $0 == "." || $0 == "/" || $0.properties.isWhitespace || ToolTextRules.isControl($0)
      }
  }
}
