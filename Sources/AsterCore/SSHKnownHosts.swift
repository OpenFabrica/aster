import Foundation

// `aster-ssh known-hosts list|remove` 的请求与结果模型，以及从已保存主机推导查询参数的纯逻辑。
//
// known_hosts 的解析与匹配只在 Rust（`SshRuntime/src/known_hosts.rs`）实现一份；这里只描述
// JSON 形状（见 `SshRuntime/PROTOCOL.md`「known-hosts 子命令」）和「该问哪些文件、哪些主机」。

/// `known-hosts list` 的请求。
public struct SSHKnownHostsListRequest: Codable, Equatable, Sendable {
  /// 除默认文件外还要列出的文件（可含 `~`；`none` 与空串由 aster-ssh 忽略）。
  public var files: [String]
  public var includeDefault: Bool
  public var includeGlobal: Bool
  /// 要判定覆盖关系的主机；hashed 记录只能靠它显示主机名。
  public var match: [SSHHostPort]

  public init(files: [String] = [], includeDefault: Bool = true, includeGlobal: Bool = true, match: [SSHHostPort] = []) {
    self.files = files
    self.includeDefault = includeDefault
    self.includeGlobal = includeGlobal
    self.match = match
  }
}

/// `known-hosts list` 的完整输出。
public struct SSHKnownHostsListing: Codable, Equatable, Sendable {
  /// 一个被列出的文件。不存在的文件也会列出（`exists == false`）。
  public struct File: Codable, Equatable, Sendable {
    public var path: String
    public var exists: Bool
    /// 文件存在、不是系统级、文件与所在目录都可写。
    public var writable: Bool
    /// 系统级文件（`/etc/ssh/ssh_known_hosts*`），一律只读。
    public var global: Bool
    /// 读取失败时的错误文本。
    public var error: String?

    public init(path: String, exists: Bool, writable: Bool, global: Bool, error: String? = nil) {
      self.path = path
      self.exists = exists
      self.writable = writable
      self.global = global
      self.error = error
    }
  }

  /// 一条主机密钥记录。
  public struct Entry: Codable, Equatable, Sendable {
    public var file: String
    /// 从 1 开始的行号。
    public var line: Int
    /// `nil`、`"revoked"` 或 `"certAuthority"`。
    public var marker: String?
    /// 主机字段按逗号拆开的原文；hashed 模式写成 `"(hashed)"`。
    public var hosts: [String]
    public var hashed: Bool
    public var algorithm: String
    /// `SHA256:…` 指纹。
    public var fingerprint: String
    public var comment: String?
    /// 请求 `match` 里被这条记录覆盖的主机。
    public var matches: [SSHHostPort]
    /// 原行的 SHA-256 十六进制；删除时用来确认行没有变。
    public var lineDigest: String

    public init(
      file: String, line: Int, marker: String? = nil, hosts: [String], hashed: Bool = false,
      algorithm: String, fingerprint: String, comment: String? = nil, matches: [SSHHostPort] = [],
      lineDigest: String
    ) {
      self.file = file
      self.line = line
      self.marker = marker
      self.hosts = hosts
      self.hashed = hashed
      self.algorithm = algorithm
      self.fingerprint = fingerprint
      self.comment = comment
      self.matches = matches
      self.lineDigest = lineDigest
    }
  }

  /// 解析不了而跳过的行。
  public struct Skipped: Codable, Equatable, Sendable {
    public var file: String
    public var line: Int
    /// `malformed` 或 `invalidKey`。
    public var reason: String

    public init(file: String, line: Int, reason: String) {
      self.file = file
      self.line = line
      self.reason = reason
    }
  }

  public var files: [File]
  public var entries: [Entry]
  public var skipped: [Skipped]

  public init(files: [File] = [], entries: [Entry] = [], skipped: [Skipped] = []) {
    self.files = files
    self.entries = entries
    self.skipped = skipped
  }
}

/// `known-hosts remove` 的请求。`host` 为 nil 时删整行，否则只删这一行里命中它的模式。
public struct SSHKnownHostsRemoveRequest: Codable, Equatable, Sendable {
  public var file: String
  public var line: Int
  public var lineDigest: String
  public var host: SSHHostPort?

  public init(file: String, line: Int, lineDigest: String, host: SSHHostPort? = nil) {
    self.file = file
    self.line = line
    self.lineDigest = lineDigest
    self.host = host
  }
}

/// `known-hosts remove` 的结果：删掉的是整行（`line`）还是行里的一个模式（`pattern`）。
public struct SSHKnownHostsRemoveResult: Codable, Equatable, Sendable {
  public var removed: String

  public init(removed: String) { self.removed = removed }
}

/// 从已保存主机与机器推导 `known-hosts list` 的查询参数。
public enum SSHKnownHostsQuery {
  /// 生成列表请求，并返回 `host:port` → 主机显示名的对照（用于在 hashed 记录旁写出主机名）。
  ///
  /// - 文件：默认文件 + 每台可解析主机（含跳板链各跳）的 `knownHostsFiles` 并集，系统级文件只读列出。
  /// - 匹配：每台可解析主机及其跳板的 `host:port`，再加上没有绑定主机的旧机器 target。
  public static func request(
    hosts: [SSHHostProfile], machineTargets: [String] = [],
    homeDirectory: String = NSHomeDirectory(), localUser: String = NSUserName()
  ) -> (request: SSHKnownHostsListRequest, names: [SSHHostPort: [String]]) {
    let resolved = SSHHostResolver.resolveAll(hosts, homeDirectory: homeDirectory, localUser: localUser).specs
    let profiles = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var files: [String] = []
    var match: [SSHHostPort] = []
    var names: [SSHHostPort: [String]] = [:]

    /// 记录一个 `host:port`（保持首次出现的顺序）与它的显示名。
    func add(_ endpoint: SSHHostPort, name: String?) {
      if names[endpoint] == nil {
        match.append(endpoint)
        names[endpoint] = []
      }
      if let name, !name.isEmpty, names[endpoint]?.contains(name) == false { names[endpoint]?.append(name) }
    }

    // 按名称排序，结果与设置页列表顺序接近，也让输出稳定、便于测试。
    let ordered = resolved.sorted { lhs, rhs in
      (profiles[lhs.key]?.name ?? "").localizedStandardCompare(profiles[rhs.key]?.name ?? "") == .orderedAscending
    }
    for (id, spec) in ordered {
      add(SSHHostPort(host: spec.host, port: spec.port), name: profiles[id]?.name)
      // 跳板各跳只记地址与文件；它们自己作为已保存主机时会带上名称。
      var hop: SSHResolvedSpec? = spec
      while let current = hop {
        for file in current.knownHostsFiles where !files.contains(file) { files.append(file) }
        if current.host != spec.host || current.port != spec.port {
          add(SSHHostPort(host: current.host, port: current.port), name: nil)
        }
        hop = current.jump?.spec
      }
    }
    for target in machineTargets {
      guard let parsed = QuickConnectTarget.parse(target) else { continue }
      add(SSHHostPort(host: parsed.host, port: parsed.effectivePort), name: nil)
    }
    return (SSHKnownHostsListRequest(files: files, match: match), names)
  }
}
