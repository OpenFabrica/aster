// 主机页右侧编辑面板的开合与宿主回调。面板盖在卡片网格右侧，网格保持可见可点；
// 切换到另一台主机前，有未保存的修改先确认是否放弃。
import AppKit
import AsterCore

extension HostsPageViewController: HostEditorPanelHost {
  // MARK: - 打开与关闭

  /// 打开编辑面板。已有面板且有未保存修改时先确认放弃；同一对象已打开时只聚焦。
  func openEditor(_ mode: HostEditorMode) {
    if let current = editorPanel {
      if current.mode == mode {
        current.focusFirstField()
        return
      }
      guard current.isDirty else {
        replaceEditor(with: mode)
        return
      }
      confirmDiscard { [weak self] in self?.replaceEditor(with: mode) }
      return
    }
    replaceEditor(with: mode)
  }

  /// 新建主机：搜索框里是地址时预填它；钻在分组里时预填该分组。
  func createHost() {
    var draft = SSHHostDraft()
    if QuickConnectTarget.looksLikeTarget(query.search), let typed = QuickConnectTarget.parse(query.search) {
      draft.name = typed.host
      draft.host = typed.host
      draft.user = typed.user ?? ""
      draft.port = typed.port.map(String.init) ?? ""
    }
    draft.group = query.group ?? ""
    openEditor(.new(draft))
  }

  /// 关闭面板（滑出后移除视图）。
  func closeEditor() {
    guard let panel = editorPanel else { return }
    editorPanel = nil
    guard let trailing = editorTrailingConstraint, view.window != nil else {
      panel.view.removeFromSuperview()
      panel.removeFromParent()
      return
    }
    editorTrailingConstraint = nil
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.16
      context.allowsImplicitAnimation = true
      trailing.animator().constant = panel.view.frame.width
    }, completionHandler: { [weak panel] in
      // 动画回调在主线程执行；滑出结束后才移除，避免面板瞬间消失。
      MainActor.assumeIsolated {
        panel?.view.removeFromSuperview()
        panel?.removeFromParent()
      }
    })
    view.window?.makeFirstResponder(searchField)
  }

  /// 换上新面板：旧面板直接移除，新面板从右侧滑入。
  private func replaceEditor(with mode: HostEditorMode) {
    if let old = editorPanel {
      old.view.removeFromSuperview()
      old.removeFromParent()
      editorPanel = nil
    }
    guard let context = makeEditorContext(mode) else {
      model.notice = L("主机不存在，可能已被删除")
      return
    }
    let panel = HostEditorPanelController(mode: mode, context: context, directory: directory, host: self)
    addChild(panel)
    let panelView = panel.view
    panelView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(panelView)
    let width = InterfaceScale.length(HostEditorMetrics.panelWidth)
    let trailing = panelView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: width)
    let preferredWidth = panelView.widthAnchor.constraint(equalToConstant: width)
    preferredWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      panelView.topAnchor.constraint(equalTo: view.topAnchor),
      panelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      panelView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
      preferredWidth, trailing,
    ])
    editorPanel = panel
    editorTrailingConstraint = trailing
    view.layoutSubtreeIfNeeded()
    if view.window != nil {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.allowsImplicitAnimation = true
        trailing.animator().constant = 0
      }
    } else {
      trailing.constant = 0
    }
    panel.focusFirstField()
  }

  /// 按模式取草稿并生成面板上下文；要编辑的主机已不存在时返回 nil。
  private func makeEditorContext(_ mode: HostEditorMode) -> HostEditorContext? {
    let hosts = directory.hosts
    let draft: SSHHostDraft
    switch mode {
    case .new(let prefilled): draft = prefilled
    case .edit(let id):
      guard let profile = hosts.first(where: { $0.id == id }), !profile.isDefaults else { return nil }
      draft = SSHHostDraft(profile: profile)
    case .defaults:
      draft = SSHHostDraft(profile: hosts.first(where: \.isDefaults) ?? .emptyDefaults())
    }
    return HostEditorContext(draft: draft, hosts: hosts, vaultKeys: editorServices.vaultKeys(), localUser: localUser)
  }

  /// 询问是否放弃未保存的修改，确认后执行 `discard`。
  private func confirmDiscard(_ discard: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = L("放弃未保存的修改？")
    alert.informativeText = L("当前编辑的主机还有没保存的修改。")
    alert.addButton(withTitle: L("放弃修改"))
    alert.addButton(withTitle: L("继续编辑"))
    present(alert) { confirmed in if confirmed { discard() } }
  }

  // MARK: - HostEditorPanelHost

  /// 面板请求关闭。
  func hostEditorDidClose(_ panel: HostEditorPanelController) {
    guard panel === editorPanel else { return }
    closeEditor()
  }

  /// 保存成功后关闭面板；卡片由目录发布的变化自动刷新。
  func hostEditor(_ panel: HostEditorPanelController, didSave profile: SSHHostProfile) {
    guard panel === editorPanel else { return }
    closeEditor()
  }

  /// 执行面板「操作」区的动作。
  func hostEditor(_ panel: HostEditorPanelController, perform action: HostEditorAction, hostID: UUID) {
    switch action {
    case .addMachine: addHostAsMachine(hostID)
    case .editSSHConfig: editSSHConfig()
    case .forgetPassword:
      confirmAndForgetPassword(hostID) { [weak panel] forgotten in
        if forgotten { panel?.refreshPasswordState() }
      }
    case .delete:
      confirmAndDeleteHost(hostID) { [weak self, weak panel] deleted in
        guard deleted, let self, let panel, panel === self.editorPanel else { return }
        self.closeEditor()
      }
    case .duplicate:
      // 复制的是已保存的配置；面板里有未保存的修改时先确认放弃，再打开副本继续编辑。
      let duplicateAndOpen = { [weak self] in
        guard let self, let copy = self.duplicateHost(hostID) else { return }
        self.replaceEditor(with: .edit(copy.id))
      }
      if panel.isDirty { confirmDiscard(duplicateAndOpen) } else { duplicateAndOpen() }
    }
  }

  /// 口令状态查询，转给后台钥匙串查询。
  func hostEditorHasPassword(hostID: UUID) async -> Bool {
    await lookupPassword(hostID: hostID)
  }
}
