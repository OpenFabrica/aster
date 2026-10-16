import Foundation

// 编辑主机时共用的纯规则：内置缺省值、继承值（表单占位符）、保存前的边界清理与跳板候选。
// 原生编辑面板与主机编辑服务都走这里，规则只有一份；最终合法性仍由 `SSHHostStore.validate` 判定。

/// 字段全部留空时生效的内置缺省值，与 `SSHHostResolver.resolve` 的兜底值一致。
public enum SSHHostBuiltinDefaults {
  public static let port = 22
  public static let auth = SSHAuthMode.auto
  public static let keepaliveInterval = 15
  public static let keepaliveCountMax = 3
  public static let connectTimeout = 10
  public static let verifyHostKeys = true
  public static let agentForward = false
  public static let identitiesOnly = false
  public static let knownHostsFiles = ["~/.ssh/known_hosts"]
  /// `identityAgent` 留空时使用的环境变量名（只用于占位提示）。
  public static let identityAgent = "SSH_AUTH_SOCK"
}

/// 某台主机留空字段时实际会用到的值，供表单占位符与「继承默认（…）」文案使用。
///
/// 普通主机先取默认项，默认项也空才取内置值；编辑默认项本身时只取内置值。
public struct SSHHostInheritedValues: Equatable, Sendable {
  public var port: Int
  public var user: String
  public var auth: SSHAuthMode
  public var identityFiles: [String]
  public var vaultKeyIDs: [UUID]
  public var identitiesOnly: Bool
  public var identityAgent: String
  public var agentForward: Bool
  /// 默认项的跳板；nil 表示不使用跳板。
  public var jumpHostID: UUID?
  public var proxyCommand: String
  public var socksProxy: SSHHostPort?
  public var httpProxy: SSHHostPort?
  /// 默认项里先生效的转发规则条数。
  public var defaultForwardCount: Int
  public var keepaliveInterval: Int
  public var keepaliveCountMax: Int
  public var connectTimeout: Int
  public var verifyHostKeys: Bool
  public var knownHostsFiles: [String]

  /// 按「编辑的是不是默认项」计算继承值。
  ///
  /// - Parameters:
  ///   - defaults: 当前默认项（缺失时传 `.emptyDefaults()`）。
  ///   - editingDefaults: 正在编辑默认项本身。
  ///   - localUser: 用户名的内置缺省值。
  public init(defaults: SSHHostProfile, editingDefaults: Bool, localUser: String) {
    // 编辑默认项时，它自己的值不是「继承来的」，占位符只显示内置值。
    let source = editingDefaults ? SSHHostProfile.emptyDefaults() : defaults
    port = source.port ?? SSHHostBuiltinDefaults.port
    let user = source.user.trimmingCharacters(in: .whitespaces)
    self.user = user.isEmpty ? localUser : user
    auth = source.auth ?? SSHHostBuiltinDefaults.auth
    identityFiles = source.identityFiles
    vaultKeyIDs = source.vaultKeyIDs ?? []
    identitiesOnly = source.identitiesOnly ?? SSHHostBuiltinDefaults.identitiesOnly
    let agent = source.identityAgent?.trimmingCharacters(in: .whitespaces) ?? ""
    identityAgent = agent.isEmpty ? SSHHostBuiltinDefaults.identityAgent : agent
    agentForward = source.agentForward ?? SSHHostBuiltinDefaults.agentForward
    jumpHostID = source.jumpHostID
    proxyCommand = source.proxyCommand ?? ""
    socksProxy = source.socksProxy
    httpProxy = source.httpProxy
    defaultForwardCount = source.forwards.count
    keepaliveInterval = source.keepaliveInterval ?? SSHHostBuiltinDefaults.keepaliveInterval
    keepaliveCountMax = source.keepaliveCountMax ?? SSHHostBuiltinDefaults.keepaliveCountMax
    connectTimeout = source.connectTimeout ?? SSHHostBuiltinDefaults.connectTimeout
    verifyHostKeys = source.verifyHostKeys ?? SSHHostBuiltinDefaults.verifyHostKeys
    knownHostsFiles =
      source.knownHostsFiles?.isEmpty == false
      ? source.knownHostsFiles ?? [] : SSHHostBuiltinDefaults.knownHostsFiles
  }
}

/// 保存前在边界做的清理被拒绝的原因。
public enum SSHHostSanitizeError: Error, Equatable, Sendable {
  /// 列表条目数超过上限（转发、私钥、known_hosts、保险库密钥）。
  case tooManyEntries
  /// 文本字段含换行或其它控制字符。
  case controlCharacters
}

/// 编辑主机的纯规则集合。
public enum SSHHostEditRules {
  public static let maximumForwards = 64
  /// 私钥文件与 known_hosts 文件各自的最多行数。
  public static let maximumIdentityFiles = 16

  /// 保存前的边界清理：空列表与空白文本统一成 nil（继承），并拒绝超量条目与控制字符。
  ///
  /// `SSHHostStore.validate` 只查 host/user/group 的换行；这里补齐其余会进入 argv 或
  /// 配置文件的文本字段。网页回传与原生表单保存都先经过这里。
  public static func sanitized(_ input: SSHHostProfile) throws(SSHHostSanitizeError) -> SSHHostProfile {
    var profile = input
    // 空 known_hosts 列表与 nil 同义（都继承默认项），统一存成 nil，文件里不留空数组。
    if profile.knownHostsFiles?.isEmpty == true { profile.knownHostsFiles = nil }
    // 保险库密钥列表同理：空数组表示继承，存成 nil。
    if profile.vaultKeyIDs?.isEmpty == true { profile.vaultKeyIDs = nil }
    // 空白的 identityAgent 同理存成 nil（继承），前后空白不属于路径。
    let identityAgent = profile.identityAgent?.trimmingCharacters(in: .whitespaces) ?? ""
    profile.identityAgent = identityAgent.isEmpty ? nil : identityAgent
    guard profile.forwards.count <= maximumForwards,
      profile.identityFiles.count <= maximumIdentityFiles,
      (profile.knownHostsFiles?.count ?? 0) <= maximumIdentityFiles,
      (profile.vaultKeyIDs?.count ?? 0) <= SSHHostStore.maximumVaultKeys
    else { throw .tooManyEntries }
    let texts =
      [
        profile.name, profile.host, profile.user, profile.group ?? "", profile.proxyCommand ?? "",
        profile.identityAgent ?? "",
      ]
      + profile.identityFiles + (profile.knownHostsFiles ?? []) + (profile.tags ?? [])
      + [profile.socksProxy?.host ?? "", profile.httpProxy?.host ?? ""]
      + profile.forwards.flatMap { [$0.bind.host, $0.target.host, $0.description] }
    let hasControl = texts.contains { text in
      text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    if hasControl { throw .controlCharacters }
    return profile
  }

  /// 跳板机候选：除自己与默认项以外的全部主机，标出选了会形成循环的那些。
  ///
  /// 沿候选主机的跳板链（自身没设就用默认项的跳板，与解析器一致）往下走，
  /// 走回到正在编辑的主机就是循环。新建主机还没被任何主机引用，不会成环。
  public static func jumpCandidates(
    for id: UUID, in hosts: [SSHHostProfile]
  ) -> [(profile: SSHHostProfile, formsCycle: Bool)] {
    let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let defaultJump = byID[SSHHostProfile.defaultsProfileID]?.jumpHostID
    /// 从 `start` 出发的跳板链是否经过 `id`。
    func reaches(from start: UUID) -> Bool {
      var visited: Set<UUID> = []
      var current = start
      while visited.insert(current).inserted {
        guard let profile = byID[current], let next = profile.jumpHostID ?? defaultJump else { return false }
        // 解析器对「跳板是自己」按直连处理（默认项的跳板主机自身），链在这里结束。
        if next == current { return false }
        if next == id { return true }
        current = next
      }
      return false
    }
    return hosts.filter { !$0.isDefaults && $0.id != id }.map { ($0, reaches(from: $0.id)) }
  }
}
