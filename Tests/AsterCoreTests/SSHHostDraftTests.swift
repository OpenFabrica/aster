// 主机编辑草稿与编辑规则：每个字段原样往返、格式错误的报告、继承占位值、边界清理与跳板成环判断。
import Foundation
import Testing

@testable import AsterCore

/// 每个字段都填了非默认值的主机，用来抓「编辑器保存后丢字段」的问题。
private func fullProfile(jump: UUID? = nil) -> SSHHostProfile {
  SSHHostProfile(
    name: "prod-db", group: "生产", host: "db.example.com", port: 2222, user: "ops", jumpHostID: jump,
    proxyCommand: "nc -X 5 %h %p", socksProxy: SSHHostPort(host: "127.0.0.1", port: 1080),
    httpProxy: SSHHostPort(host: "::1", port: 8080), auth: .publicKey,
    identityFiles: ["~/.ssh/id_ed25519", "~/.ssh/%h"], identitiesOnly: true,
    knownHostsFiles: ["~/.orbstack/ssh/known_hosts"], identityAgent: "~/.1password/agent.sock",
    agentForward: false,
    forwards: [
      SSHForwardRule(
        kind: .local, bind: SSHHostPort(host: "127.0.0.1", port: 5432),
        target: SSHHostPort(host: "localhost", port: 5432), description: "pg"),
      SSHForwardRule(
        kind: .remote, bind: SSHHostPort(host: "0.0.0.0", port: 9000),
        target: SSHHostPort(host: "fe80::1", port: 22)),
      SSHForwardRule(
        kind: .dynamic, bind: SSHHostPort(host: "127.0.0.1", port: 1081), target: SSHHostPort(host: "", port: 0)),
    ],
    keepaliveInterval: 30, keepaliveCountMax: 5, connectTimeout: 7, verifyHostKeys: false,
    tags: ["prod", "db"], vaultKeyIDs: [UUID(), UUID()])
}

@Test("草稿往返：每个 SSHHostProfile 字段原样保留（含标签与保险库密钥顺序）")
func hostDraftRoundTripsEveryField() throws {
  let profile = fullProfile(jump: UUID())
  let draft = SSHHostDraft(profile: profile)
  #expect(try draft.makeProfile() == profile)
  // 全空的主机与默认项也原样往返。
  let bare = SSHHostProfile(name: "bare", host: "10.0.0.1")
  #expect(try SSHHostDraft(profile: bare).makeProfile() == bare)
  var defaults = fullProfile()
  defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", port: defaults.port, user: defaults.user,
    proxyCommand: defaults.proxyCommand, auth: defaults.auth, identityFiles: defaults.identityFiles,
    identitiesOnly: true, knownHostsFiles: defaults.knownHostsFiles, identityAgent: defaults.identityAgent,
    forwards: defaults.forwards, keepaliveInterval: 20, verifyHostKeys: true, vaultKeyIDs: defaults.vaultKeyIDs)
  let defaultsDraft = SSHHostDraft(profile: defaults)
  #expect(defaultsDraft.isDefaults)
  #expect(try defaultsDraft.makeProfile() == defaults)
}

@Test("草稿组装：空文本存成继承（nil），去空白，默认项不写分组与标签")
func hostDraftNormalizesEmptyValues() throws {
  var draft = SSHHostDraft(id: UUID())
  draft.name = "  web  "
  draft.host = " web.example.com "
  draft.group = "   "
  draft.tags = [" prod ", "PROD", ""]
  draft.identityFiles = "\n ~/.ssh/a \n\n"
  draft.knownHostsFiles = "  \n"
  draft.identityAgent = "  "
  draft.proxyCommand = " "
  let profile = try draft.makeProfile()
  #expect(profile.name == "web" && profile.host == "web.example.com")
  #expect(profile.group == nil && profile.tags == ["prod"])
  #expect(profile.identityFiles == ["~/.ssh/a"])
  #expect(profile.knownHostsFiles == nil && profile.identityAgent == nil && profile.proxyCommand == nil)
  #expect(profile.port == nil && profile.vaultKeyIDs == nil && profile.auth == nil)

  var defaults = SSHHostDraft(profile: .emptyDefaults())
  defaults.group = "x"
  defaults.tags = ["x"]
  defaults.host = "ignored"
  let saved = try defaults.makeProfile()
  #expect(saved.group == nil && saved.tags == nil && saved.host == "" && saved.name == "Defaults")
}

@Test("草稿组装：非整数、代理与转发地址格式错误一次全部报告")
func hostDraftReportsFormatIssues() {
  var draft = SSHHostDraft(profile: SSHHostProfile(name: "a", host: "a"))
  draft.port = "22a"
  draft.connectTimeout = "1.5"
  draft.socksProxy = "1080"
  draft.forwards = [
    SSHHostDraft.Forward(kind: .local, bind: "8080", target: "80"),
    SSHHostDraft.Forward(kind: .remote, bind: "x:y", target: "localhost:80"),
    SSHHostDraft.Forward(kind: .dynamic, bind: "1081", target: "garbage"),
  ]
  #expect(throws: SSHHostDraftError(issues: [
    .notInteger(.port), .notInteger(.connectTimeout), .notHostPort(.socksProxy), .forwardAddress(index: 2),
  ])) { try draft.makeProfile() }
  // 只写端口时按 ssh 习惯补地址；动态转发忽略目标。
  draft.port = ""
  draft.connectTimeout = ""
  draft.socksProxy = ""
  draft.forwards.remove(at: 1)
  let profile = try? draft.makeProfile()
  #expect(profile?.forwards.map(\.bind) == [
    SSHHostPort(host: "127.0.0.1", port: 8080), SSHHostPort(host: "127.0.0.1", port: 1081),
  ])
  #expect(profile?.forwards.map(\.target) == [
    SSHHostPort(host: "localhost", port: 80), SSHHostPort(host: "", port: 0),
  ])
}

@Test("主机:端口解析与格式化：IPv6 方括号、纯端口回退主机、非法输入")
func hostDraftHostPortParsing() {
  #expect(SSHHostDraft.parseHostPort("[::1]:22") == SSHHostPort(host: "::1", port: 22))
  #expect(SSHHostDraft.parseHostPort(" proxy.local : 3128 ") == SSHHostPort(host: "proxy.local", port: 3128))
  #expect(SSHHostDraft.parseHostPort("8080", fallbackHost: "127.0.0.1") == SSHHostPort(host: "127.0.0.1", port: 8080))
  for bad in ["", "8080", ":80", "host:", "host:8o", "[::1]", "[::1]x22", "host:-1"] {
    #expect(SSHHostDraft.parseHostPort(bad) == nil, "\(bad)")
  }
  #expect(SSHHostDraft.formatHostPort(SSHHostPort(host: "fe80::1", port: 22)) == "[fe80::1]:22")
  #expect(SSHHostDraft.formatHostPort(SSHHostPort(host: "", port: 9)) == "9")
  #expect(SSHHostDraft.formatHostPort(nil) == "")
  #expect(SSHHostDraft.parseTags("prod，db, PROD,, ") == ["prod", "db"])
}

@Test("保险库密钥勾选：取消即移除，勾选追加末尾，其余（含已删除的 ID）顺序不变")
func hostDraftVaultKeySelectionKeepsOrder() {
  let (a, b, gone) = (UUID(), UUID(), UUID())
  var draft = SSHHostDraft(profile: SSHHostProfile(name: "a", host: "a", vaultKeyIDs: [b, gone, a]))
  draft.setVaultKey(b, selected: false)
  #expect(draft.vaultKeyIDs == [gone, a])
  draft.setVaultKey(b, selected: true)
  #expect(draft.vaultKeyIDs == [gone, a, b])
  draft.setVaultKey(a, selected: true)
  #expect(draft.vaultKeyIDs == [gone, b, a])
}

@Test("继承值：普通主机先取默认项再取内置值；编辑默认项只显示内置值")
func hostInheritedValues() {
  let jump = UUID()
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", port: 2200, user: "  ", jumpHostID: jump,
    auth: .agent, identityFiles: ["~/.ssh/work"], identitiesOnly: true, knownHostsFiles: [],
    forwards: [SSHForwardRule(kind: .dynamic, bind: SSHHostPort(host: "127.0.0.1", port: 1), target: SSHHostPort(host: "", port: 0))],
    keepaliveInterval: 60, verifyHostKeys: false)
  let host = SSHHostInheritedValues(defaults: defaults, editingDefaults: false, localUser: "me")
  #expect(host.port == 2200 && host.user == "me" && host.auth == .agent && host.jumpHostID == jump)
  #expect(host.identityFiles == ["~/.ssh/work"] && host.identitiesOnly && !host.verifyHostKeys)
  #expect(host.keepaliveInterval == 60 && host.keepaliveCountMax == 3 && host.connectTimeout == 10)
  #expect(host.knownHostsFiles == ["~/.ssh/known_hosts"] && host.identityAgent == "SSH_AUTH_SOCK")
  #expect(host.defaultForwardCount == 1)
  let builtin = SSHHostInheritedValues(defaults: defaults, editingDefaults: true, localUser: "me")
  #expect(builtin.port == 22 && builtin.auth == .auto && builtin.jumpHostID == nil)
  #expect(builtin.keepaliveInterval == 15 && builtin.verifyHostKeys && builtin.defaultForwardCount == 0)
}

@Test("边界清理：空列表与空白存成 nil；超量条目与控制字符被拒")
func hostEditRulesSanitize() throws {
  var profile = SSHHostProfile(name: "a", host: "a", knownHostsFiles: [], identityAgent: "  ", vaultKeyIDs: [])
  let clean = try SSHHostEditRules.sanitized(profile)
  #expect(clean.knownHostsFiles == nil && clean.identityAgent == nil && clean.vaultKeyIDs == nil)
  profile.identityFiles = Array(repeating: "~/.ssh/k", count: SSHHostEditRules.maximumIdentityFiles + 1)
  #expect(throws: SSHHostSanitizeError.tooManyEntries) { try SSHHostEditRules.sanitized(profile) }
  profile.identityFiles = []
  profile.forwards = [
    SSHForwardRule(kind: .local, bind: SSHHostPort(host: "a", port: 1), target: SSHHostPort(host: "b", port: 2), description: "x\ty")
  ]
  #expect(throws: SSHHostSanitizeError.controlCharacters) { try SSHHostEditRules.sanitized(profile) }
}

@Test("跳板候选：排除自己与默认项；沿跳板链（含默认项的跳板）能走回自己的主机标为成环")
func hostEditRulesJumpCandidates() {
  let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
  var defaults = SSHHostProfile.emptyDefaults()
  let hosts = [
    defaults,
    SSHHostProfile(id: a, name: "a", host: "a"),
    SSHHostProfile(id: b, name: "b", host: "b", jumpHostID: a),
    SSHHostProfile(id: c, name: "c", host: "c", jumpHostID: b),
    SSHHostProfile(id: d, name: "d", host: "d"),
  ]
  let candidates = SSHHostEditRules.jumpCandidates(for: a, in: hosts)
  #expect(candidates.map(\.profile.id) == [b, c, d])
  #expect(candidates.map(\.formsCycle) == [true, true, false])
  // 默认项的跳板是 a：没写跳板的 d 也会经过 a，选 d 作 a 的跳板就成环；a 自己的跳板链在 a 处结束。
  defaults.jumpHostID = a
  let viaDefaults = SSHHostEditRules.jumpCandidates(for: a, in: [defaults] + hosts.dropFirst())
  #expect(viaDefaults.first { $0.profile.id == d }?.formsCycle == true)
  // 新建主机还没被任何主机引用，不会成环。
  #expect(SSHHostEditRules.jumpCandidates(for: UUID(), in: hosts).allSatisfy { !$0.formsCycle })
}
