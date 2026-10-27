// 工具中心：插件登记、搜索、打开工具与管理。扫描在后台进行，结果按代次回到主线程；
// 启用与授权只存 tools-state.json。设计见 docs/developer/tools-and-plugins.md。
import AppKit
import AsterCore
import Combine

/// 工具中心：插件登记、搜索、打开工具与管理。所有成员都在主线程使用。
@MainActor
final class ToolCenter: ToolManaging {
  static let shared = ToolCenter()

  private let environment: ToolCenterEnvironment
  private let stateStore: ToolStateStore
  private let changeSubject = PassthroughSubject<Void, Never>()
  /// 最近一次扫描得到的插件（含停用的），顺序：内置原生、内置网页、用户、开发。
  private var records: [ToolPluginRecord]
  private var scanIssues: [ToolPluginIssue] = []
  private var entriesByID: [String: ToolCatalogEntry] = [:]
  /// 每次发起扫描加一；只有最新一代的结果会被应用，迟到的旧结果丢弃。
  private var scanGeneration = 0
  private var appliedGeneration = 0
  private var scanWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var watcher: ToolPluginWatcher?
  private var sessionReferences: [ToolSessionReference] = []
  /// 正在进行的授权确认；同一插件重复请求时共用一个确认框。
  private var approvals: [String: Task<Bool, Never>] = [:]
  private var isStarted = false
  private var cancellables: Set<AnyCancellable> = []
  /// 删除 WebKit 数据存储的尝试次数与间隔（WebView 释放后约 200 ms 内可以删除）。
  static let websiteDataRemovalAttempts = 5
  static let websiteDataRetryDelay: Duration = .milliseconds(150)

  /// 已启用且可运行（或待确认）的全部功能。
  private(set) var catalog: [ToolCatalogEntry] = []

  /// App 使用的共享实例：真实目录与原生确认框。
  convenience init() {
    self.init(environment: .live())
  }

  /// 按给定环境创建；状态文件在这里同步读一次（很小，有大小上限），插件要等 `start()` 或 `reload()` 才扫描。
  init(environment: ToolCenterEnvironment) {
    self.environment = environment
    stateStore = ToolStateStore(
      fileURL: environment.applicationSupportDirectory.appendingPathComponent(ToolStateFile.fileName),
      usageSaveDelay: environment.usageSaveDelay)
    records = [ToolPluginRecord(manifest: BuiltinToolCatalog.manifest(), source: .builtin, directory: nil, digest: nil)]
    rebuildCatalog()
  }

  // MARK: 启动与查询

  /// App 启动时调用一次：建插件目录、清理安装残留、首次扫描、开始监听；App 退出前把状态写完。
  func start() {
    guard !isStarted else { return }
    isStarted = true
    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.stateStore.flush() } }
      .store(in: &cancellables)
    if environment.watchesFileSystem {
      let watcher = ToolPluginWatcher()
      watcher.onChange = { [weak self] folders in self?.handleFileSystemChange(folders) }
      self.watcher = watcher
    }
    let directory = pluginsDirectory
    Task {
      await ToolCenterBackground.preparePluginsDirectory(directory)
      await reloadAndWait()
    }
  }

  /// 关键词搜索；空查询返回最常用的工具。
  func search(_ query: String, limit: Int) -> [ToolMatch] {
    ToolMatcher.search(query, entries: catalog, usage: stateStore.state.usage, now: Date(), limit: limit)
  }

  /// 输入内容命中的工具（「识别到」）。
  func contentMatches(for input: ToolInput, limit: Int) -> [ToolMatch] {
    ToolMatcher.contentMatches(for: input, entries: catalog, usage: stateStore.state.usage, now: Date(), limit: limit)
  }

  /// 内置转换可以立即给出的结果；没有就返回 nil。
  func inlineResult(for entry: ToolCatalogEntry, input: ToolInput) -> String? {
    guard case .builtin(let action) = entry.feature.action, let text = input.text else { return nil }
    return BuiltinTextTools.inlineResult(action.handler, input: text, now: Date(), timeZone: .current)
  }

  /// 按功能 id（`<pluginID>/<code>`）查条目。
  func entry(id: String) -> ToolCatalogEntry? {
    entriesByID[id]
  }

  /// 记一次使用，用于排序；写盘去抖。
  func recordUse(entryID: String) {
    stateStore.recordUse(entryID, at: Date())
  }

  /// 组装当前环境（界面语言、外观、来源 Pane 的目录）。
  func makeContext(workingDirectory: String?, isRemote: Bool) -> ToolContext {
    let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return ToolContext(
      workingDirectory: workingDirectory, isRemote: isRemote, locale: AppLocalization.current.rawValue,
      appearance: isDark ? "dark" : "light")
  }

  /// 为一次打开工具创建展示控制器。需要授权的插件由控制器自己先显示授权提示。
  func makeSession(for request: ToolLaunchRequest, host: ToolSessionHost) -> ToolSessionViewController {
    let session = ToolSessionViewController(request: request, host: host, center: self)
    sessionReferences.removeAll { $0.session == nil }
    sessionReferences.append(ToolSessionReference(session: session))
    return session
  }

  /// 运行插件需要的信息；插件不存在、没有目录（内置原生工具）或不是可运行状态时为 nil。
  func runtimeInfo(pluginID: String) -> ToolPluginRuntimeInfo? {
    guard let record = record(id: pluginID), let directory = record.directory, status(of: record) == .ready else {
      return nil
    }
    // 可用权限与域名的规则（内置全给；其它取「声明 ∩ 已授权」）只在 ToolPluginTrust 定义一次。
    let state = stateStore.state.plugins[pluginID]
    return ToolPluginRuntimeInfo(
      manifest: record.manifest, source: record.source, directory: directory,
      dataDirectory: dataDirectory(for: pluginID),
      grantedPermissions: ToolPluginTrust.effectivePermissions(
        manifest: record.manifest, source: record.source, state: state),
      grantedNetworkDomains: ToolPluginTrust.effectiveNetworkDomains(
        manifest: record.manifest, source: record.source, state: state))
  }

  // MARK: 会话使用的查询

  /// 插件当前状态；找不到返回 nil。
  func pluginStatus(pluginID: String) -> ToolPluginStatus? {
    record(id: pluginID).map(status(of:))
  }

  /// 插件清单；找不到返回 nil。
  func manifest(pluginID: String) -> ToolManifest? {
    record(id: pluginID)?.manifest
  }

  /// 运行前的最后确认：用户来源插件在后台重算文件摘要，和授权时不同就重新扫描（状态随之变成需要确认）。
  /// 监听只看插件目录一层，原地改写插件文件靠这里拦住。
  func prepareToRun(pluginID: String) async -> ToolPluginStatus? {
    guard let record = record(id: pluginID) else { return nil }
    guard record.source == .user, let directory = record.directory, status(of: record) == .ready else {
      return status(of: record)
    }
    let approved = stateStore.state.plugins[pluginID]?.approvedDigest
    if await ToolCenterBackground.digest(of: directory) != approved { await reloadAndWait() }
    return pluginStatus(pluginID: pluginID)
  }

  /// `<AppSupport>/PluginData/<id>/`。
  func dataDirectory(for pluginID: String) -> URL {
    environment.applicationSupportDirectory
      .appendingPathComponent("PluginData", isDirectory: true)
      .appendingPathComponent(pluginID, isDirectory: true)
  }

  /// 原生工具用的终端主题与字体。
  func terminalStyle() -> ToolTerminalStyle {
    environment.terminalStyle()
  }

  /// 会话释放后从登记里移除。
  func sessionDidTearDown(_ session: ToolSessionViewController) {
    sessionReferences.removeAll { $0.session == nil || $0.session === session }
  }

  /// 立即写出尚未落盘的状态并等写完（测试与退出前使用）。
  func flushState() {
    stateStore.flush()
  }

  // MARK: ToolManaging

  var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }

  var pluginSummaries: [ToolPluginSummary] {
    records.map { record in
      let manifest = displayManifest(of: record)
      let declared = ToolPluginTrust.permissionsRequiringConsent(manifest)
      let state = stateStore.state.plugins[record.id]
      // 保持 `declared` 的风险排序，是否已授权按 ToolPluginTrust 的统一规则判断。
      let effective = ToolPluginTrust.effectivePermissions(manifest: manifest, source: record.source, state: state)
      let granted = declared.filter(effective.contains)
      // 开发来源给登记的原字符串：设置页按它和 developmentFolders 逐字比对来显示「移除」。
      return ToolPluginSummary(
        id: record.id, name: manifest.name, version: manifest.version,
        description: manifest.description, source: record.source,
        directory: record.registeredPath ?? record.directory?.path ?? "", status: status(of: record),
        permissions: declared, grantedPermissions: granted, networkDomains: manifest.network,
        featureCount: manifest.features.count)
    }
  }

  var pluginIssues: [ToolPluginIssue] {
    (stateStore.loadIssue.map { [$0] } ?? []) + scanIssues
  }

  var pluginsDirectory: URL {
    environment.applicationSupportDirectory.appendingPathComponent("Plugins", isDirectory: true)
  }

  var developmentFolders: [String] { stateStore.state.developmentFolders }

  /// 重新扫描（后台进行，完成后发出 `changes`）。
  func reload() {
    Task { await reloadAndWait() }
  }

  /// 发起一次后台扫描，并等到它或之后发起的扫描应用完成。
  func reloadAndWait() async {
    scanGeneration += 1
    let generation = scanGeneration
    let result = await ToolCenterBackground.scan(scanLocations)
    if generation == scanGeneration {
      apply(result)
      appliedGeneration = generation
      let finished = scanWaiters.filter { $0.generation <= generation }
      scanWaiters.removeAll { $0.generation <= generation }
      finished.forEach { $0.continuation.resume() }
    } else if appliedGeneration < generation {
      // 被更新的一次扫描取代：等它应用，调用方看到的一定是不早于本次发起时的结果。
      await withCheckedContinuation { scanWaiters.append((generation, $0)) }
    }
  }

  func setEnabled(_ enabled: Bool, pluginID: String) {
    stateStore.update { state in
      if enabled {
        guard var existing = state.plugins[pluginID] else { return }
        existing.enabled = true
        // 只是被停用过、从没授权：删掉记录，状态回到「第一次运行」而不是「权限变多」。
        let pristine = existing.grantedPermissions.isEmpty && existing.grantedNetworkDomains.isEmpty
          && existing.approvedDigest == nil && existing.approvedVersion == nil
        state.plugins[pluginID] = pristine ? nil : existing
      } else {
        var existing = state.plugins[pluginID] ?? ToolPluginState(enabled: false)
        existing.enabled = false
        state.plugins[pluginID] = existing
      }
    }
    refreshDerivedState()
  }

  func approve(pluginID: String, window: NSWindow?) async -> Bool {
    if let running = approvals[pluginID] { return await running.value }
    let task = Task { await self.performApproval(pluginID: pluginID, window: window) }
    approvals[pluginID] = task
    let approved = await task.value
    approvals[pluginID] = nil
    return approved
  }

  func installPlugin(from folder: URL, window: NSWindow?) async throws -> String {
    let candidate = try await ToolCenterBackground.inspect(folder, source: .user)
    let manifest = candidate.manifest
    guard record(id: manifest.id) == nil else { throw ToolCenterError.alreadyInstalled(manifest.id) }
    guard let directory = candidate.directory, let digest = candidate.digest else {
      throw ToolCenterError.fileOperationFailed(folder.path)
    }
    let prompt = ToolInstallPrompt(kind: .install, manifest: manifest, source: .user, directory: directory.path)
    guard await environment.approver.requestApproval(for: prompt, window: window) else {
      throw ToolCenterError.declined
    }
    try await ToolCenterBackground.install(directory, id: manifest.id, digest: digest, into: pluginsDirectory)
    stateStore.update {
      $0.plugins[manifest.id] = ToolPluginTrust.approvedState(manifest: manifest, digest: digest, previous: nil)
    }
    await reloadAndWait()
    return manifest.id
  }

  func addDevelopmentFolder(_ folder: URL, window: NSWindow?) async throws -> String {
    let candidate = try await ToolCenterBackground.inspect(folder, source: .development)
    let manifest = candidate.manifest
    let path = candidate.directory?.path ?? folder.path
    guard !developmentFolders.contains(path), record(id: manifest.id) == nil else {
      throw ToolCenterError.alreadyInstalled(manifest.id)
    }
    let prompt = ToolInstallPrompt(kind: .developmentFolder, manifest: manifest, source: .development, directory: path)
    guard await environment.approver.requestApproval(for: prompt, window: window) else {
      throw ToolCenterError.declined
    }
    stateStore.update { state in
      if !state.developmentFolders.contains(path) { state.developmentFolders.append(path) }
      state.plugins[manifest.id] = ToolPluginTrust.approvedState(
        manifest: manifest, digest: nil, previous: state.plugins[manifest.id])
    }
    await reloadAndWait()
    return manifest.id
  }

  /// 取消登记开发目录（不动目录里的文件），并撤销从它加载的插件的授权。
  func removeDevelopmentFolder(_ path: String) {
    guard developmentFolders.contains(path) else { return }
    let removedIDs = records.filter { $0.source == .development && $0.registeredPath == path }.map(\.id)
    stateStore.update { state in
      state.developmentFolders.removeAll { $0 == path }
      for id in removedIDs { state.plugins[id] = nil }
    }
    Task { await reloadAndWait() }
  }

  /// 卸载，按顺序：撤下正在用它的会话 → 删 WebKit 数据存储 → 删 `PluginData/<id>/` → 用户插件目录移到废纸篓
  /// （开发目录只取消登记、不动文件）→ 清掉授权与使用记录。任何一步失败都停在那里并抛错，已撤下的会话
  /// 随重新扫描恢复；WebKit 存储排在最前，删不掉时插件还完整可用。
  func uninstall(pluginID: String) async throws {
    guard let record = record(id: pluginID) else { throw ToolCenterError.pluginNotFound(pluginID) }
    guard record.source != .builtin else { throw ToolCenterError.notRemovable(pluginID) }
    activeSessions(pluginID: pluginID).forEach { $0.pluginWasRemoved() }
    do {
      try await removeWebsiteData(pluginID: pluginID)
      try await ToolCenterBackground.removeDirectory(dataDirectory(for: pluginID))
      if record.source == .user, let directory = record.directory {
        try await ToolCenterBackground.moveToTrash(directory, using: environment.moveToTrash)
      }
    } catch {
      await reloadAndWait()
      throw error
    }
    stateStore.update { state in
      if record.source == .development, let path = record.registeredPath {
        state.developmentFolders.removeAll { $0 == path }
      }
      state.plugins[pluginID] = nil
      state.usage.removeRecords(forPluginID: pluginID)
    }
    await reloadAndWait()
  }

  // MARK: 内部

  /// 扫描要看的位置。
  private var scanLocations: ToolPluginScanLocations {
    ToolPluginScanLocations(
      builtinDirectory: environment.resourcesDirectory?.appendingPathComponent("tools-builtin", isDirectory: true),
      userDirectory: pluginsDirectory, developmentFolders: developmentFolders)
  }

  /// 按 id 找插件记录。
  private func record(id: String) -> ToolPluginRecord? {
    records.first { $0.id == id }
  }

  /// 用当前授权记录判断插件状态。
  private func status(of record: ToolPluginRecord) -> ToolPluginStatus {
    ToolPluginTrust.status(
      manifest: record.manifest, source: record.source, state: stateStore.state.plugins[record.id],
      currentDigest: record.digest)
  }

  /// 正在使用某插件的会话。
  private func activeSessions(pluginID: String? = nil) -> [ToolSessionViewController] {
    sessionReferences.compactMap(\.session).filter { pluginID == nil || $0.request.entry.pluginID == pluginID }
  }

  /// 显示用的清单：内置网页插件的文案按界面语言翻译；原生内置工具的清单本来就由 `L()` 生成，
  /// 用户与开发插件原样显示。
  private func displayManifest(of record: ToolPluginRecord) -> ToolManifest {
    guard record.source == .builtin, record.id != BuiltinToolCatalog.pluginID else { return record.manifest }
    return record.manifest.localizedForBuiltin(environment.translateBuiltinText)
  }

  /// 删除插件的 WebKit 数据存储。刚撤下的 WebView 要过一小会儿才真正释放，期间 WebKit 报「仍在使用」，
  /// 所以间隔重试几次；仍失败就抛错，让卸载停在还没删任何文件的时候。
  private func removeWebsiteData(pluginID: String) async throws {
    let identifier = ToolPluginIdentity.dataStoreIdentifier(pluginID: pluginID)
    var lastError: Error?
    for attempt in 0..<Self.websiteDataRemovalAttempts {
      if attempt > 0 {
        do {
          try await Task.sleep(for: Self.websiteDataRetryDelay)
        } catch {
          break
        }
      }
      do {
        try await environment.removeWebsiteData(identifier)
        return
      } catch {
        lastError = error
      }
    }
    DiagnosticsCenter.shared.record(
      "tools.website_data_remove_failed", level: .warning, category: .storage, error: lastError)
    throw ToolCenterError.fileOperationFailed(L("插件的网页数据还在使用，请关掉正在打开它的工具后重试"))
  }

  /// 应用一次扫描结果：替换插件列表与问题、重建目录、通知会话与监听、发出变化。
  private func apply(_ result: ToolPluginScanResult) {
    records = result.records
    scanIssues = result.issues
    watcher?.configure(userDirectory: pluginsDirectory, developmentFolders: developmentFolders)
    refreshDerivedState()
  }

  /// 状态或插件列表变化后的统一收尾。
  private func refreshDerivedState() {
    rebuildCatalog()
    activeSessions().forEach { $0.pluginStateDidChange() }
    changeSubject.send()
  }

  /// 重建启动器目录：停用的插件不列；图标取功能图标，没有再用插件图标。内置网页插件用翻译后的标题，
  /// 搜索与「识别到」的标签也就跟原生内置工具一样随界面语言变化。
  private func rebuildCatalog() {
    var entries: [ToolCatalogEntry] = []
    for record in records where status(of: record) != .disabled {
      let manifest = displayManifest(of: record)
      for feature in manifest.features {
        entries.append(
          ToolCatalogEntry(
            pluginID: record.id, pluginName: manifest.name, pluginVersion: manifest.version,
            source: record.source, feature: feature,
            iconPath: record.featureIconPaths[feature.code] ?? record.iconPath, hasUI: manifest.ui != nil))
      }
    }
    catalog = entries
    entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // 搜索接口是主线程同步调用，第一次搜索要为每个标题做拼音转换。目录变化后在后台先搜一次，
    // 把归一化结果写进 ToolSearchText 的全局缓存（有锁），用户第一次打字时就不再卡这一下。
    Task.detached(priority: .utility) {
      _ = ToolMatcher.search("a", entries: entries, usage: ToolUsageStats(), now: Date(), limit: 1)
    }
  }

  /// 文件系统变化：重新扫描；开发目录的文件变了，让正在打开的网页工具重新加载。
  private func handleFileSystemChange(_ folders: Set<String>) {
    Task {
      await reloadAndWait()
      guard !folders.isEmpty else { return }
      let changedIDs = Set(
        records.filter { $0.source == .development && folders.contains($0.registeredPath ?? "") }.map(\.id))
      for session in activeSessions() where changedIDs.contains(session.request.entry.pluginID) {
        session.pluginFilesDidChange()
      }
    }
  }

  /// 授权确认的实际流程。确认期间插件可能被重新扫描或卸载，只在清单与摘要仍是用户看到的那份时写入授权。
  private func performApproval(pluginID: String, window: NSWindow?) async -> Bool {
    // 用户来源先重新扫描一次：让用户确认的是磁盘上现在的清单与摘要。
    if record(id: pluginID)?.source == .user { await reloadAndWait() }
    guard let record = record(id: pluginID) else { return false }
    if status(of: record) == .ready { return true }
    var enabledState = stateStore.state.plugins[pluginID]
    enabledState?.enabled = true
    let effective = ToolPluginTrust.status(
      manifest: record.manifest, source: record.source, state: enabledState, currentDigest: record.digest)
    guard case .needsApproval(let reason) = effective else {
      // 只是被停用，不缺授权：直接启用。
      setEnabled(true, pluginID: pluginID)
      return true
    }
    let prompt = ToolInstallPrompt(
      kind: .approval(reason), manifest: record.manifest, source: record.source,
      directory: record.directory?.path ?? "")
    guard await environment.approver.requestApproval(for: prompt, window: window) else { return false }
    guard let current = self.record(id: pluginID), current.manifest == record.manifest,
      current.digest == record.digest, current.source == record.source
    else { return false }
    stateStore.update {
      $0.plugins[pluginID] = ToolPluginTrust.approvedState(
        manifest: record.manifest, digest: record.digest, previous: $0.plugins[pluginID])
    }
    refreshDerivedState()
    return true
  }
}

/// 对会话的弱引用；会话关闭后自然失效。
@MainActor
private final class ToolSessionReference {
  weak var session: ToolSessionViewController?

  init(session: ToolSessionViewController) {
    self.session = session
  }
}
