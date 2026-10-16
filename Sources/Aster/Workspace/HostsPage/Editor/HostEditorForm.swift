// 编辑面板的表单：按「基本 / 认证 / 跳板与代理 / 端口转发 / 高级」分区摆放全部主机字段，
// 并在保存时把控件内容收回成 `SSHHostDraft`。字段、占位符与继承文案与网页表单（`hosts-form.js`）一致：
// 空字段表示继承默认项，占位符写出将要生效的值。
import AppKit
import AsterCore

/// 打开编辑面板时需要的只读上下文。全部来自 `SSHHostDirectory` 与保险库的当前快照。
struct HostEditorContext {
  /// 要编辑的草稿（新建主机时是预填后的空草稿）。
  var draft: SSHHostDraft
  /// 全部主机（含默认项），用于跳板候选。
  var hosts: [SSHHostProfile]
  var inherited: SSHHostInheritedValues
  /// 已有分组与标签，供下拉与补全。
  var groups: [String]
  var tags: [String]
  var vaultKeys: [SSHVaultKey]

  /// 从主机列表推出上下文。`localUser` 是用户名的内置缺省值。
  @MainActor init(draft: SSHHostDraft, hosts: [SSHHostProfile], vaultKeys: [SSHVaultKey], localUser: String) {
    self.draft = draft
    self.hosts = hosts
    let defaults = hosts.first(where: \.isDefaults) ?? .emptyDefaults()
    inherited = SSHHostInheritedValues(defaults: defaults, editingDefaults: draft.isDefaults, localUser: localUser)
    let saved = SSHHostEditing.sorted(hosts.filter { !$0.isDefaults })
    groups = SSHHostEditing.orderedGroups(saved)
    tags = SSHHostEditing.orderedTags(saved)
    self.vaultKeys = vaultKeys
  }
}

/// 表单控件与读写。`delegate` 接收全部单行输入框的回调（Esc 关闭、回车保存）。
@MainActor
final class HostEditorForm: NSObject, NSTokenFieldDelegate {
  let context: HostEditorContext
  private(set) var sections: [HostEditorSectionView] = []
  private weak var fieldDelegate: NSTextFieldDelegate?

  // 基本
  private(set) var nameField: HostEditorTextField?
  private(set) var groupField: HostEditorTextField?
  private(set) var tagsField: HostEditorTextField?
  private(set) var hostField: HostEditorTextField?
  let portField: HostEditorTextField
  let userField: HostEditorTextField
  // 认证
  let authPopUp = HostEditorPopUp(identifier: "host-editor-auth")
  let identityFiles: HostEditorTextArea
  let vaultKeys: HostEditorVaultKeysView
  let identitiesOnlyPopUp = HostEditorPopUp(identifier: "host-editor-identities-only")
  let identityAgentField: HostEditorTextField
  let agentForwardPopUp = HostEditorPopUp(identifier: "host-editor-agent-forward")
  // 跳板与代理
  let jumpPopUp = HostEditorPopUp(identifier: "host-editor-jump")
  let proxyCommandField: HostEditorTextField
  let socksField: HostEditorTextField
  let httpField: HostEditorTextField
  // 端口转发
  let forwards: HostEditorForwardsView
  // 高级
  let keepaliveIntervalField: HostEditorTextField
  let keepaliveCountField: HostEditorTextField
  let connectTimeoutField: HostEditorTextField
  let verifyHostKeysPopUp = HostEditorPopUp(identifier: "host-editor-verify-host-keys")
  let knownHostsFiles: HostEditorTextArea

  /// 按上下文建好全部控件并填入草稿值；`sections` 按显示顺序排列。
  init(context: HostEditorContext, fieldDelegate: NSTextFieldDelegate?) {
    self.context = context
    self.fieldDelegate = fieldDelegate
    let draft = context.draft
    let inherited = context.inherited
    let isDefaults = draft.isDefaults
    portField = HostEditorTextField(placeholder: String(inherited.port), identifier: "host-editor-port")
    userField = HostEditorTextField(placeholder: inherited.user, identifier: "host-editor-user")
    identityFiles = HostEditorTextArea(
      placeholder: inherited.identityFiles.isEmpty || isDefaults
        ? "~/.ssh/id_ed25519" : inherited.identityFiles.joined(separator: "\n"),
      identifier: "host-editor-identity-files")
    vaultKeys = HostEditorVaultKeysView(
      selection: draft.vaultKeyIDs, keys: context.vaultKeys, inheritedIDs: inherited.vaultKeyIDs,
      isDefaults: isDefaults)
    identityAgentField = HostEditorTextField(
      placeholder: inherited.identityAgent, identifier: "host-editor-identity-agent", monospaced: true)
    proxyCommandField = HostEditorTextField(
      placeholder: inherited.proxyCommand, identifier: "host-editor-proxy-command", monospaced: true)
    socksField = HostEditorTextField(
      placeholder: SSHHostDraft.formatHostPort(inherited.socksProxy).nonEmpty ?? "127.0.0.1:1080",
      identifier: "host-editor-socks-proxy", monospaced: true)
    httpField = HostEditorTextField(
      placeholder: SSHHostDraft.formatHostPort(inherited.httpProxy).nonEmpty ?? "127.0.0.1:8080",
      identifier: "host-editor-http-proxy", monospaced: true)
    forwards = HostEditorForwardsView(
      rules: draft.forwards, defaultRuleCount: isDefaults ? 0 : inherited.defaultForwardCount,
      fieldDelegate: fieldDelegate)
    keepaliveIntervalField = HostEditorTextField(
      placeholder: String(inherited.keepaliveInterval), identifier: "host-editor-keepalive-interval")
    keepaliveCountField = HostEditorTextField(
      placeholder: String(inherited.keepaliveCountMax), identifier: "host-editor-keepalive-count")
    connectTimeoutField = HostEditorTextField(
      placeholder: String(inherited.connectTimeout), identifier: "host-editor-connect-timeout")
    knownHostsFiles = HostEditorTextArea(
      placeholder: inherited.knownHostsFiles.joined(separator: "\n"), identifier: "host-editor-known-hosts-files",
      lines: 2)
    super.init()
    if !isDefaults {
      nameField = HostEditorTextField(placeholder: L("例如：生产数据库"), identifier: "host-editor-name")
      groupField = HostEditorTextField(placeholder: L("未分组"), identifier: "host-editor-group")
      tagsField = HostEditorTextField(
        placeholder: L("例如：prod, db"), identifier: "host-editor-tags", field: NSTokenField())
      hostField = HostEditorTextField(placeholder: "example.com", identifier: "host-editor-host", monospaced: true)
    }
    configureChoices()
    populate(draft)
    for field in allTextFields where field.field.delegate == nil { field.field.delegate = fieldDelegate }
    if let token = tagsField?.field as? NSTokenField {
      token.delegate = self
      token.tokenizingCharacterSet = CharacterSet(charactersIn: ",，")
      token.tokenStyle = .rounded
    }
    sections = buildSections()
  }

  /// 全部单行输入框（含转发规则以外的），用于统一设置代理与测试。
  var allTextFields: [HostEditorTextField] {
    [nameField, groupField, tagsField, hostField].compactMap { $0 } + [
      portField, userField, identityAgentField, proxyCommandField, socksField, httpField,
      keepaliveIntervalField, keepaliveCountField, connectTimeoutField,
    ]
  }

  /// 第一个应获得焦点的输入框：普通主机是名称，默认项是端口。
  var initialFirstResponder: NSView { nameField?.field ?? portField.field }

  // MARK: - 选项

  /// 填充认证方式、三态开关与跳板机下拉。
  private func configureChoices() {
    let inherited = context.inherited
    authPopUp.addItem(inheritLabel(Self.authLabel(inherited.auth)), value: nil)
    for mode in SSHAuthMode.allCases { authPopUp.addItem(Self.authLabel(mode), value: mode) }
    for (popUp, value) in [
      (identitiesOnlyPopUp, inherited.identitiesOnly), (agentForwardPopUp, inherited.agentForward),
      (verifyHostKeysPopUp, inherited.verifyHostKeys),
    ] {
      popUp.addItem(inheritLabel(value ? L("开") : L("关")), value: nil)
      popUp.addItem(L("开"), value: true)
      popUp.addItem(L("关"), value: false)
    }
    // 跳板机：不能选自己，也不列出默认项；选了会成环的主机灰显。
    let names = Dictionary(context.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let defaultJumpName = inherited.jumpHostID.flatMap { names[$0] }
    jumpPopUp.addItem(
      context.draft.isDefaults ? L("不使用跳板") : inheritLabel(defaultJumpName ?? L("不使用跳板")), value: nil)
    let candidates = SSHHostEditRules.jumpCandidates(for: context.draft.id, in: context.hosts)
    let order = SSHHostEditing.sorted(candidates.map(\.profile)).map(\.id)
    let cycles = Dictionary(candidates.map { ($0.profile.id, $0.formsCycle) }, uniquingKeysWith: { first, _ in first })
    for id in order {
      guard let profile = context.hosts.first(where: { $0.id == id }) else { continue }
      let cycle = cycles[id] ?? false
      jumpPopUp.addItem(
        "\(profile.name)（\(profile.connectString)）", value: id, enabled: !cycle,
        toolTip: cycle ? L("跳板机形成了循环") : nil)
    }
  }

  /// 「继承默认（…）」或编辑默认项时的「内置默认（…）」。
  private func inheritLabel(_ text: String) -> String {
    context.draft.isDefaults ? L("内置默认（\(text)）") : L("继承默认（\(text)）")
  }

  /// 认证方式的显示文案（与网页表单一致）。
  static func authLabel(_ mode: SSHAuthMode) -> String {
    switch mode {
    case .auto: L("自动")
    case .password: L("口令")
    case .publicKey: L("公钥")
    case .agent: "Agent"
    case .keyboardInteractive: L("键盘交互")
    }
  }

  // MARK: - 读写

  /// 把草稿值填进控件。
  private func populate(_ draft: SSHHostDraft) {
    nameField?.stringValue = draft.name
    groupField?.stringValue = draft.group
    (tagsField?.field as? NSTokenField)?.objectValue = draft.tags
    hostField?.stringValue = draft.host
    portField.stringValue = draft.port
    userField.stringValue = draft.user
    authPopUp.select { ($0 as? SSHAuthMode) == draft.auth }
    identityFiles.stringValue = draft.identityFiles
    identitiesOnlyPopUp.select { ($0 as? Bool) == draft.identitiesOnly }
    identityAgentField.stringValue = draft.identityAgent
    agentForwardPopUp.select { ($0 as? Bool) == draft.agentForward }
    jumpPopUp.select { ($0 as? UUID) == draft.jumpHostID }
    proxyCommandField.stringValue = draft.proxyCommand
    socksField.stringValue = draft.socksProxy
    httpField.stringValue = draft.httpProxy
    keepaliveIntervalField.stringValue = draft.keepaliveInterval
    keepaliveCountField.stringValue = draft.keepaliveCountMax
    connectTimeoutField.stringValue = draft.connectTimeout
    verifyHostKeysPopUp.select { ($0 as? Bool) == draft.verifyHostKeys }
    knownHostsFiles.stringValue = draft.knownHostsFiles
  }

  /// 把控件内容收回成草稿。没有显示的字段（默认项的名称等）沿用原草稿。
  func currentDraft() -> SSHHostDraft {
    var draft = context.draft
    if let nameField { draft.name = nameField.stringValue }
    if let groupField { draft.group = groupField.stringValue }
    if let token = tagsField?.field as? NSTokenField {
      draft.tags = (token.objectValue as? [Any] ?? []).map { "\($0)" }
    }
    if let hostField { draft.host = hostField.stringValue }
    draft.port = portField.stringValue
    draft.user = userField.stringValue
    draft.auth = authPopUp.selectedValue as? SSHAuthMode
    draft.identityFiles = identityFiles.stringValue
    draft.vaultKeyIDs = vaultKeys.selection
    draft.identitiesOnly = identitiesOnlyPopUp.selectedValue as? Bool
    draft.identityAgent = identityAgentField.stringValue
    draft.agentForward = agentForwardPopUp.selectedValue as? Bool
    draft.jumpHostID = jumpPopUp.selectedValue as? UUID
    draft.proxyCommand = proxyCommandField.stringValue
    draft.socksProxy = socksField.stringValue
    draft.httpProxy = httpField.stringValue
    draft.forwards = forwards.currentRules()
    draft.keepaliveInterval = keepaliveIntervalField.stringValue
    draft.keepaliveCountMax = keepaliveCountField.stringValue
    draft.connectTimeout = connectTimeoutField.stringValue
    draft.verifyHostKeys = verifyHostKeysPopUp.selectedValue as? Bool
    draft.knownHostsFiles = knownHostsFiles.stringValue
    return draft
  }

  // MARK: - 标签补全

  /// 标签补全：已有标签里以输入开头、且还没用过的（不分大小写）。
  func tokenField(
    _ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
  ) -> [Any]? {
    let used = Set((tokenField.objectValue as? [Any] ?? []).map { "\($0)".lowercased() })
    let prefix = substring.lowercased()
    return context.tags.filter { !used.contains($0.lowercased()) && $0.lowercased().hasPrefix(prefix) }
  }

  /// 标签输入框也转发 Esc / 回车给面板。
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    // 回车在令牌框里用来确认令牌，只转发 Esc。
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    return fieldDelegate?.control?(control, textView: textView, doCommandBy: selector) ?? false
  }
}

extension String {
  /// 非空时返回自身，空串返回 nil。
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
