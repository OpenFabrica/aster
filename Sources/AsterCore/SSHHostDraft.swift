import Foundation

// 主机编辑表单的草稿：把 `SSHHostProfile` 拆成表单里的文本与选项，再按同一套规则组装回去。
//
// 原生编辑面板直接使用。格式规则：空字段表示继承默认项，
// `主机:端口` 可省略主机（转发规则按 ssh 习惯补 127.0.0.1 / localhost）。这里只做格式解析，
// 是否合法仍由 `SSHHostStore.validate` 与解析器最终判定。
// 每个 `SSHHostProfile` 字段都必须在 `init(profile:)` 与 `makeProfile()` 之间原样往返，
// 新增字段时两边一起改，否则从编辑器保存会悄悄丢掉它。

/// 主机编辑草稿。文本字段保存用户输入的原文，组装时才解析。
public struct SSHHostDraft: Equatable, Sendable {
  /// 一条端口转发规则的草稿。`bind` / `target` 是 `主机:端口` 文本。
  public struct Forward: Equatable, Sendable {
    public var kind: SSHForwardKind
    public var bind: String
    public var target: String
    public var description: String

    public init(kind: SSHForwardKind = .local, bind: String = "", target: String = "", description: String = "") {
      self.kind = kind
      self.bind = bind
      self.target = target
      self.description = description
    }
  }

  /// 原主机 ID；新建主机由调用方生成。
  public let id: UUID
  public var isDefaults: Bool { id == SSHHostProfile.defaultsProfileID }
  /// 默认项的名称不在表单里显示，组装时原样带回。
  public var name: String
  public var group: String
  public var tags: [String]
  public var host: String
  public var port: String
  public var user: String
  /// nil 表示继承默认项。
  public var auth: SSHAuthMode?
  /// 每行一个私钥路径。
  public var identityFiles: String
  /// 选中的保险库密钥，保持原顺序；勾选新密钥追加到末尾。找不到的 ID 原样保留。
  public var vaultKeyIDs: [UUID]
  public var identitiesOnly: Bool?
  public var identityAgent: String
  public var agentForward: Bool?
  public var jumpHostID: UUID?
  public var proxyCommand: String
  public var socksProxy: String
  public var httpProxy: String
  public var forwards: [Forward]
  public var keepaliveInterval: String
  public var keepaliveCountMax: String
  public var connectTimeout: String
  public var verifyHostKeys: Bool?
  /// 每行一个 known_hosts 文件。
  public var knownHostsFiles: String

  /// 新建主机的空草稿。
  public init(id: UUID = UUID()) {
    self.init(profile: SSHHostProfile(id: id, name: ""))
  }

  /// 从已保存的主机生成草稿。
  public init(profile: SSHHostProfile) {
    id = profile.id
    name = profile.name
    group = profile.group ?? ""
    tags = profile.tags ?? []
    host = profile.host
    port = profile.port.map(String.init) ?? ""
    user = profile.user
    auth = profile.auth
    identityFiles = profile.identityFiles.joined(separator: "\n")
    vaultKeyIDs = profile.vaultKeyIDs ?? []
    identitiesOnly = profile.identitiesOnly
    identityAgent = profile.identityAgent ?? ""
    agentForward = profile.agentForward
    jumpHostID = profile.jumpHostID
    proxyCommand = profile.proxyCommand ?? ""
    socksProxy = Self.formatHostPort(profile.socksProxy)
    httpProxy = Self.formatHostPort(profile.httpProxy)
    forwards = profile.forwards.map {
      Forward(
        kind: $0.kind, bind: Self.formatHostPort($0.bind),
        target: $0.kind == .dynamic ? "" : Self.formatHostPort($0.target), description: $0.description)
    }
    keepaliveInterval = profile.keepaliveInterval.map(String.init) ?? ""
    keepaliveCountMax = profile.keepaliveCountMax.map(String.init) ?? ""
    connectTimeout = profile.connectTimeout.map(String.init) ?? ""
    verifyHostKeys = profile.verifyHostKeys
    knownHostsFiles = (profile.knownHostsFiles ?? []).joined(separator: "\n")
  }

  // MARK: - 组装

  /// 把草稿组装成主机配置；格式错误时一次报告全部问题。
  ///
  /// 空文本存成 nil（继承），默认项不写名称以外的身份字段。
  public func makeProfile() throws(SSHHostDraftError) -> SSHHostProfile {
    var issues: [SSHHostDraftIssue] = []
    /// 可空整数字段：空串为 nil，非整数记一条问题。
    func integer(_ text: String, _ field: SSHHostDraftField) -> Int? {
      let value = text.trimmingCharacters(in: .whitespaces)
      guard !value.isEmpty else { return nil }
      guard let number = Int(value) else {
        issues.append(.notInteger(field))
        return nil
      }
      return number
    }
    /// 代理地址：必须写成 `主机:端口`。
    func proxy(_ text: String, _ field: SSHHostDraftField) -> SSHHostPort? {
      guard !Self.trimmed(text).isEmpty else { return nil }
      guard let parsed = Self.parseHostPort(text) else {
        issues.append(.notHostPort(field))
        return nil
      }
      return parsed
    }

    let port = integer(port, .port)
    let keepaliveInterval = integer(keepaliveInterval, .keepaliveInterval)
    let keepaliveCountMax = integer(keepaliveCountMax, .keepaliveCountMax)
    let connectTimeout = integer(connectTimeout, .connectTimeout)
    let socksProxy = proxy(socksProxy, .socksProxy)
    let httpProxy = proxy(httpProxy, .httpProxy)
    var rules: [SSHForwardRule] = []
    for (index, rule) in forwards.enumerated() {
      // 只写端口时绑定本机回环、目标 localhost，与 ssh -L 8080:… 的习惯一致；动态转发没有目标。
      let bind = Self.parseHostPort(rule.bind, fallbackHost: "127.0.0.1")
      let target =
        rule.kind == .dynamic
        ? SSHHostPort(host: "", port: 0) : Self.parseHostPort(rule.target, fallbackHost: "localhost")
      guard let bind, let target else {
        issues.append(.forwardAddress(index: index + 1))
        continue
      }
      rules.append(
        SSHForwardRule(kind: rule.kind, bind: bind, target: target, description: Self.trimmed(rule.description)))
    }
    guard issues.isEmpty else { throw SSHHostDraftError(issues: issues) }

    // 标签已经是令牌数组，不再按逗号拆；含逗号的标签交给存储校验拒绝。
    let tags = SSHHostStore.normalizedTags(tags) ?? []
    let identityFiles = Self.lines(identityFiles)
    let knownHostsFiles = Self.lines(knownHostsFiles)
    return SSHHostProfile(
      id: id,
      name: isDefaults ? name : Self.trimmed(name),
      group: isDefaults ? nil : Self.nonEmpty(group),
      host: isDefaults ? "" : Self.trimmed(host),
      port: port,
      user: Self.trimmed(user),
      jumpHostID: jumpHostID,
      proxyCommand: Self.nonEmpty(proxyCommand),
      socksProxy: socksProxy,
      httpProxy: httpProxy,
      auth: auth,
      identityFiles: identityFiles,
      identitiesOnly: identitiesOnly,
      knownHostsFiles: knownHostsFiles.isEmpty ? nil : knownHostsFiles,
      identityAgent: Self.nonEmpty(identityAgent),
      agentForward: agentForward,
      forwards: rules,
      keepaliveInterval: keepaliveInterval,
      keepaliveCountMax: keepaliveCountMax,
      connectTimeout: connectTimeout,
      verifyHostKeys: verifyHostKeys,
      tags: isDefaults || tags.isEmpty ? nil : tags,
      vaultKeyIDs: vaultKeyIDs.isEmpty ? nil : vaultKeyIDs)
  }

  /// 勾选或取消一把保险库密钥：取消就移除，勾选追加到末尾，其余顺序不变。
  public mutating func setVaultKey(_ id: UUID, selected: Bool) {
    vaultKeyIDs.removeAll { $0 == id }
    if selected { vaultKeyIDs.append(id) }
  }

  // MARK: - 文本格式

  /// 解析 `host:port`、`[v6]:port` 或纯端口；纯端口时用 `fallbackHost`，没有就视为格式不对。
  public static func parseHostPort(_ text: String, fallbackHost: String? = nil) -> SSHHostPort? {
    let value = trimmed(text)
    guard !value.isEmpty else { return nil }
    var host = fallbackHost
    var port = Substring(value)
    if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
      // `[v6]:port`：方括号里是 IPv6，冒号之后必须是端口。
      let rest = value[value.index(after: close)...]
      guard rest.hasPrefix(":") else { return nil }
      host = String(value[value.index(after: value.startIndex)..<close])
      port = rest.dropFirst()
    } else if let colon = value.lastIndex(of: ":") {
      host = trimmed(String(value[..<colon]))
      port = Substring(trimmed(String(value[value.index(after: colon)...])))
    }
    guard let host, !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber),
      let number = Int(port)
    else { return nil }
    return SSHHostPort(host: host, port: number)
  }

  /// 把 `SSHHostPort` 显示成输入框文本；IPv6 加方括号，主机为空时只写端口。
  public static func formatHostPort(_ value: SSHHostPort?) -> String {
    guard let value else { return "" }
    guard !value.host.isEmpty else { return String(value.port) }
    let host = value.host.contains(":") ? "[\(value.host)]" : value.host
    return "\(host):\(value.port)"
  }

  /// 逗号（含中文逗号）分隔的标签文本拆成数组：去空白、丢空串、不分大小写去重。
  public static func parseTags(_ text: String) -> [String] {
    SSHHostStore.normalizedTags(text.split(whereSeparator: { $0 == "," || $0 == "，" }).map(String.init)) ?? []
  }

  /// 多行文本按行拆分，去空白、丢空行。
  public static func lines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map { trimmed(String($0)) }.filter { !$0.isEmpty }
  }

  /// 去掉首尾空白（含换行）。
  static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 去空白后非空才返回。
  static func nonEmpty(_ text: String) -> String? {
    let value = trimmed(text)
    return value.isEmpty ? nil : value
  }
}

// MARK: - 格式问题

/// 表单里需要按名称报错的字段。
public enum SSHHostDraftField: String, Sendable, CaseIterable {
  case port
  case keepaliveInterval
  case keepaliveCountMax
  case connectTimeout
  case socksProxy
  case httpProxy

  /// 字段在表单上的标签文案。
  public var label: String {
    switch self {
    case .port: L("端口")
    case .keepaliveInterval: L("Keepalive 间隔（秒）")
    case .keepaliveCountMax: L("Keepalive 次数")
    case .connectTimeout: L("连接超时（秒）")
    case .socksProxy: L("SOCKS 代理")
    case .httpProxy: L("HTTP 代理")
    }
  }
}

/// 草稿里的一处格式问题。
public enum SSHHostDraftIssue: Equatable, Sendable {
  case notInteger(SSHHostDraftField)
  case notHostPort(SSHHostDraftField)
  /// 第 `index` 条（从 1 开始）转发规则的地址格式不对。
  case forwardAddress(index: Int)

  /// 给用户看的一句话。
  public var message: String {
    switch self {
    case .notInteger(let field): L("\(field.label) 必须是整数")
    case .notHostPort(let field): L("\(field.label) 要写成 主机:端口")
    case .forwardAddress(let index): L("第 \(String(index)) 条转发规则的地址要写成 主机:端口")
    }
  }
}

/// 草稿无法组装成主机配置。
public struct SSHHostDraftError: Error, Equatable, Sendable {
  public var issues: [SSHHostDraftIssue]

  public init(issues: [SSHHostDraftIssue]) { self.issues = issues }

  /// 全部问题用「；」连成一句。
  public var message: String { issues.map(\.message).joined(separator: "；") }
}
