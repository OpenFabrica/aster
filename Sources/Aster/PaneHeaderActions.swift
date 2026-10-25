import AppKit
import AsterCore

extension WorkspaceTitlePopoverViewController {
  var session: TerminalSession? { tab?.runtime(for: paneID)?.terminalSession }

  var targetIsCurrent: Bool {
    guard let tab else { return false }
    return model.tabs.contains(where: { $0 === tab })
      && model.selectedTabID == tab.id && tab.activePaneID == paneID
      && tab.runtime(for: paneID) != nil
  }

  var directory: String? {
    session?.resolvedCurrentWorkingDirectory()
      ?? tab?.runtime(for: paneID)?.descriptor.workingDirectory
  }

  var displayDirectory: String {
    guard let directory else { return L("不可用") }
    let path = (directory as NSString).abbreviatingWithTildeInPath
    return path.hasSuffix("/") ? path : path + "/"
  }

  var isRemote: Bool {
    session.map { !$0.currentWorkingDirectoryIsLocal || $0.nativeSSH != nil
      || $0.remoteManagedMachineLabel != nil } ?? false
  }

  var localDirectoryIsAvailable: Bool {
    guard !isRemote, let directory, directory.hasPrefix("/") else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  var privilegeSymbols: [String] {
    guard let values = session?.resolvedPrivileges else { return [] }
    return [values.terminalBell || values.soundOnErrorExit ? "speaker.wave.2" : "speaker.slash",
      values.notifyOnFinish || values.notifyOnError || values.notifyOnWatchFinish
        || values.notificationShellControlled ? "bell" : "bell.slash"]
  }

  func dismiss() {
    guard !isDismissing else { return }
    isDismissing = true
    stopDismissalMonitoring()
    gitLoadTask?.cancel()
    menuPresenter.close()
    onDismiss?()
  }

  func performNavigation(_ action: (AppModel) -> Void) {
    guard targetIsCurrent else { dismiss(); return }
    dismiss()
    action(model)
  }

  func copyPath() {
    guard targetIsCurrent, let directory else { dismiss(); return }
    pasteboard.clearContents()
    pasteboard.setString(directory, forType: .string)
    dismiss()
  }

  func revealInFinder() {
    guard targetIsCurrent, localDirectoryIsAvailable, let directory else { dismiss(); return }
    dismiss()
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
  }

  func showOpenInMenu(from sender: WorkspaceTitleRowButton) {
    let menu = PaneDirectoryApplications.menu(directory: directory, isRemote: isRemote) {
      result in
      if case .failure(let error) = result { NSAlert(error: error).runModal() }
    }
    presentMenu(menu, from: sender)
  }

  func showGitMenu(from sender: WorkspaceTitleRowButton) {
    if menuPresenter.isPresenting(sender) {
      if NSApp.currentEvent?.type == .keyDown { menuPresenter.focusFirstItem() }
      return
    }
    gitLoadTask?.cancel()
    let loading = NSMenu(title: "Git")
    loading.autoenablesItems = false
    let status = NSMenuItem(title: L("正在读取仓库…"), action: nil, keyEquivalent: "")
    status.isEnabled = false
    loading.addItem(status)
    presentMenu(loading, from: sender)
    // Keep the owning workspace window for sheets after the transient popover closes.
    let owner = ownerWindow
    let model = model
    let tab = tab
    let paneID = paneID
    let controller = PaneGitMenu(directory: directory, isRemote: isRemote,
      window: { [weak owner] in owner },
      beforeAction: { [weak model, weak tab, weak owner] in
        guard let model, let tab, owner?.isVisible == true else { return false }
        return model.tabs.contains { $0 === tab } && tab.runtime(for: paneID) != nil
      },
      onDismiss: { [weak self] in self?.dismiss() })
    gitMenuController = controller
    gitLoadTask = Task { [weak self, weak sender] in
      let menu: NSMenu
      do { menu = try await controller.load() }
      catch is CancellationError { return }
      catch {
        menu = NSMenu(title: "Git")
        menu.autoenablesItems = false
        let item = NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = error.localizedDescription
        menu.addItem(item)
      }
      guard !Task.isCancelled, let self, let sender, self.targetIsCurrent,
        self.menuPresenter.isPresenting(sender) else { return }
      let keyboard = self.menuPresenter.hasKeyboardFocus
      self.menuPresenter.close()
      self.presentMenu(menu, from: sender)
      if keyboard { self.menuPresenter.focusFirstItem() }
    }
  }

  func splitMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (title, direction) in [
      (L("向右分屏"), SplitDirection.right), (L("向左分屏"), .left),
      (L("向下分屏"), .down), (L("向上分屏"), .up),
    ] {
      let item = ActionMenuItem(title: title) { [weak self] in
        self?.performNavigation { $0.splitSelectedTab(direction) }
      }
      item.identifier = NSUserInterfaceItemIdentifier("pane-split-\(direction.rawValue)")
      item.isEnabled = targetIsCurrent
      item.keyEquivalent = "d"
      item.keyEquivalentModifierMask = switch direction {
      case .right: .command
      case .left: [.command, .option]
      case .down: [.command, .shift]
      case .up: [.command, .option, .shift]
      }
      menu.addItem(item)
    }
    return menu
  }

  func showSplitMenu(from sender: WorkspaceTitleRowButton) {
    presentMenu(splitMenu(), from: sender)
  }

  func showPrivilegesMenu(from sender: WorkspaceTitleRowButton) {
    guard let session, targetIsCurrent else { return }
    let menu = PanePrivilegesMenu.make(session: session, preferences: preferences) { [weak self] in
      self?.toggleCaffeinate()
    }
    presentMenu(menu, from: sender, keepOpen: true)
    menuPresenter.afterAction = { [weak self, weak sender] in
      guard let self, let sender, !self.isDismissing, self.targetIsCurrent else { return }
      sender.setStatusSymbols(self.privilegeSymbols)
      self.menuPresenter.close()
      self.showPrivilegesMenu(from: sender)
    }
  }

  /// A one-task lease ends at the next command completion; all-tasks lasts until explicitly off.
  func toggleCaffeinate() {
    guard let session, targetIsCurrent else { return }
    let state = session.privilegesState
    if state.caffeinateMode != .off { state.setCaffeinateMode(.off); return }
    guard let owner = ownerWindow else { return }
    let model = model
    let tab = tab
    let paneID = paneID
    dismiss()
    let alert = NSAlert()
    alert.messageText = L("保持 macOS 唤醒")
    alert.informativeText = L("此 Pane 的任务运行期间阻止系统睡眠。")
    alert.addButton(withTitle: L("仅本次任务"))
    alert.addButton(withTitle: L("所有任务"))
    alert.addButton(withTitle: L("取消"))
    alert.beginSheetModal(for: owner) { [weak model, weak tab] result in
      guard let model, let tab, model.tabs.contains(where: { $0 === tab }),
        tab.runtime(for: paneID) != nil else { return }
      switch result {
      case .alertFirstButtonReturn:
        let running = Set(tab.runtimes.values.compactMap(\.terminalSession)
          .filter(\.hasRunningCommand).map(\.id))
        state.setCaffeinateMode(.forThisTask, sessionIDs: running.isEmpty ? [session.id] : running)
      case .alertSecondButtonReturn:
        state.setCaffeinateMode(.forAllTasks)
      default: break
      }
    }
  }

  func aboutMenu() -> NSMenu {
    let menu = NSMenu(title: L("关于此 Pane"))
    menu.autoenablesItems = false
    func info(_ label: String, _ value: String) {
      let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.toolTip = value
      menu.addItem(item)
    }
    info("Pane ID", paneID.uuidString)
    if let session {
      let raw = session.paneCommandSummary.replacingOccurrences(of: "\n", with: " ⏎ ")
      let summary = raw.count >= 61 ? String(raw.prefix(59)) + "…" : raw
      info(session.activeAgentProvider == nil ? L("命令") : "TUI", summary)
    }
    if let date = tab?.runtime(for: paneID)?.openedAt {
      info(L("打开时间"), date.formatted(date: .abbreviated, time: .standard))
    }
    let device = session?.remoteManagedMachineLabel
      ?? session?.remoteWorkingDirectory?.host
      ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    info(L("设备"), device + (isRemote ? " · SSH" : " · macOS"))
    menu.addItem(.separator())
    let copy = ActionMenuItem(title: L("复制 Pane ID")) { [weak self] in
      guard let self, self.targetIsCurrent else { return }
      self.pasteboard.clearContents()
      self.pasteboard.setString(self.paneID.uuidString, forType: .string)
    }
    copy.identifier = NSUserInterfaceItemIdentifier("pane-copy-id")
    menu.addItem(copy)
    return menu
  }

  func showAboutMenu(from sender: WorkspaceTitleRowButton) {
    presentMenu(aboutMenu(), from: sender)
  }

  private func presentMenu(_ menu: NSMenu, from row: WorkspaceTitleRowButton, keepOpen: Bool = false) {
    guard !isDismissing, targetIsCurrent else { dismiss(); return }
    menuPresenter.beforeAction = { [weak self] in
      guard let self, self.targetIsCurrent else { self?.dismiss(); return false }
      return true
    }
    menuPresenter.afterAction = { [weak self] in
      if !keepOpen { self?.dismiss() }
    }
    menuPresenter.show(menu, from: row)
    if let event = NSApp.currentEvent, event.type == .keyDown { menuPresenter.focusFirstItem() }
  }
}
