// 编辑面板表单的分区摆放：基本 / 认证 / 跳板与代理 / 端口转发 / 高级。
// 有内容的分区默认展开，空的进阶分区默认收起，与网页表单「有内容才展开」一致。
import AppKit
import AsterCore

extension HostEditorForm {
  /// 按显示顺序建好全部分区。
  func buildSections() -> [HostEditorSectionView] {
    [basicSection(), authSection(), jumpSection(), forwardsSection(), advancedSection()]
  }

  /// 基本：名称、分组、标签、主机与端口、用户（默认项只有端口与用户）。
  private func basicSection() -> HostEditorSectionView {
    let section = HostEditorSectionView(title: L("基本"), identifier: "host-editor-section-basic", expanded: true)
    if let nameField { section.addRow(makeHostEditorField(L("名称"), control: nameField)) }
    if let groupField {
      groupField.setAccessory(makeGroupMenuButton(for: groupField))
      section.addRow(makeHostEditorField(L("分组"), control: groupField))
    }
    if let tagsField {
      section.addRow(makeHostEditorField(L("标签"), control: tagsField, hint: L("用逗号分隔，最多 16 个")))
    }
    let port = makeHostEditorField(L("端口"), control: portField)
    if let hostField {
      section.addRow(makeHostEditorPair(makeHostEditorField(L("主机"), control: hostField), port, leadingFraction: 0.7))
    } else {
      section.addRow(port)
    }
    section.addRow(makeHostEditorField(L("用户"), control: userField))
    return section
  }

  /// 认证：认证方式、私钥文件、保险库密钥、只用指定私钥、Agent 套接字与转发。
  private func authSection() -> HostEditorSectionView {
    let section = HostEditorSectionView(title: L("认证"), identifier: "host-editor-section-auth", expanded: true)
    section.addRow(makeHostEditorField(L("认证方式"), control: authPopUp))
    section.addRow(
      makeHostEditorField(L("私钥文件"), control: identityFiles, hint: L("每行一个；可用 ~、%h（主机）、%r（用户）")))
    section.addRow(makeHostEditorField(L("保险库密钥"), control: vaultKeys))
    section.addRow(
      makeHostEditorField(
        L("只用指定私钥"), control: identitiesOnlyPopUp,
        hint: L("开启后只尝试上面的私钥文件，不再用 agent 里的其它密钥（IdentitiesOnly）")))
    section.addRow(
      makeHostEditorField(
        L("Agent 套接字"), control: identityAgentField,
        hint: L("认证用的 ssh-agent 套接字路径（IdentityAgent），可用 ~；填 none 不用 agent，留空使用 SSH_AUTH_SOCK")))
    section.addRow(makeHostEditorField(L("Agent 转发"), control: agentForwardPopUp))
    return section
  }

  /// 跳板与代理：跳板机、ProxyCommand、SOCKS / HTTP 代理。
  private func jumpSection() -> HostEditorSectionView {
    let draft = context.draft
    let hasContent =
      draft.jumpHostID != nil || [draft.proxyCommand, draft.socksProxy, draft.httpProxy].contains { !$0.isEmpty }
    let section = HostEditorSectionView(
      title: L("跳板与代理"), identifier: "host-editor-section-jump", expanded: hasContent)
    section.addRow(makeHostEditorField(L("跳板机"), control: jumpPopUp))
    section.addRow(
      makeHostEditorField("ProxyCommand", control: proxyCommandField, hint: L("填写后不再直连；%h、%p 由 ssh 规则展开")))
    section.addRow(makeHostEditorField(L("SOCKS 代理"), control: socksField))
    section.addRow(makeHostEditorField(L("HTTP 代理"), control: httpField))
    return section
  }

  /// 端口转发：规则列表。
  private func forwardsSection() -> HostEditorSectionView {
    let section = HostEditorSectionView(
      title: L("端口转发"), identifier: "host-editor-section-forwards", expanded: !context.draft.forwards.isEmpty)
    section.addRow(forwards)
    return section
  }

  /// 高级：keepalive、连接超时、主机密钥校验与 known_hosts 文件。
  private func advancedSection() -> HostEditorSectionView {
    let draft = context.draft
    let hasContent =
      [draft.keepaliveInterval, draft.keepaliveCountMax, draft.connectTimeout, draft.knownHostsFiles]
      .contains { !$0.isEmpty } || draft.verifyHostKeys != nil
    let section = HostEditorSectionView(
      title: L("高级"), identifier: "host-editor-section-advanced", expanded: hasContent)
    section.addRow(
      makeHostEditorPair(
        makeHostEditorField(L("Keepalive 间隔（秒）"), control: keepaliveIntervalField),
        makeHostEditorField(L("Keepalive 次数"), control: keepaliveCountField)))
    section.addRow(makeHostEditorField(L("连接超时（秒）"), control: connectTimeoutField))
    section.addRow(makeHostEditorField(L("校验主机密钥"), control: verifyHostKeysPopUp))
    let builtinPath = SSHHostBuiltinDefaults.knownHostsFiles.joined(separator: "、")
    section.addRow(
      makeHostEditorField(
        L("known_hosts 文件"), control: knownHostsFiles, hint: L("每行一个；留空使用默认值 \(builtinPath)")))
    return section
  }

  /// 分组输入框右侧的下拉按钮：列出已有分组，选中即填入。
  private func makeGroupMenuButton(for field: HostEditorTextField) -> NSView {
    let groups = context.groups
    let button = HostsPagePillButton(
      title: "", symbol: "chevron.down", showsBackground: false,
      menuProvider: { [weak field] in
        let menu = NSMenu()
        menu.autoenablesItems = false
        if groups.isEmpty {
          let none = NSMenuItem(title: L("还没有分组"), action: nil, keyEquivalent: "")
          none.isEnabled = false
          menu.addItem(none)
        }
        for group in groups {
          menu.addItem(ActionMenuItem(title: group) { [weak field] in field?.stringValue = group })
        }
        return menu
      })
    button.identifier = NSUserInterfaceItemIdentifier("host-editor-group-menu")
    button.toolTip = L("选择已有分组")
    // 胶囊按钮默认 30pt 高，放进 30pt 的输入框里要缩小。
    for constraint in button.constraints where constraint.firstAttribute == .height {
      constraint.constant = InterfaceScale.length(24)
    }
    button.widthAnchor.constraint(equalToConstant: InterfaceScale.length(24)).isActive = true
    return button
  }
}
