import AsterCore
import Combine
import Foundation

// 私钥保险库的 App 侧唯一权威入口：读写 ssh-keys.json、监听外部修改、发布变化，
// 并保证目录与钥匙串的一致：私钥先进钥匙串再登记目录，删除时目录、钥匙串、主机引用一起清理。
// 设置页与 broker 同步都从这里读，不各自持有副本。
// 钥匙串读写可能很慢（钥匙串锁住、系统弹窗），一律放到后台执行，主线程只改目录与缓存。

/// 保险库操作失败。
enum SSHVaultKeyDirectoryError: Error, Equatable {
  /// 找不到这把密钥（可能已被删除）。
  case unknownKey
  /// 钥匙串写入或删除失败。
  case keychain(SSHCredentialStoreError)
  /// 目录文件读写或校验失败。
  case store(SSHVaultKeyStoreError)
  /// 目录已登记，但钥匙串里的私钥没删掉。
  case keychainCleanupFailed(SSHCredentialStoreError)
}

/// 私钥保险库目录。
@MainActor
final class SSHVaultKeyDirectory: ObservableObject {
  static let shared = SSHVaultKeyDirectory(hostDirectory: { .shared })

  /// 当前有效密钥列表（保存顺序）。
  @Published private(set) var keys: [SSHVaultKey]
  /// 最近一次加载失败的原因；nil 表示正常。失败时 `keys` 保持最后有效值。
  @Published private(set) var loadError: String?
  /// 钥匙串里找不到私钥的密钥 ID。后台查询的缓存：加载、目录变化、增删时刷新，
  /// 结果回到主线程才写入；第一次刷新完成前视为都不缺。
  @Published private(set) var keychainMissing: Set<UUID> = []

  let store: SSHVaultKeyStore
  let credentials: any SSHCredentialStoring
  private let hostDirectory: () -> SSHHostDirectory
  private var watcher: FileSystemDirectoryWatcher?
  /// 每次发起钥匙串存在性刷新递增；回来的结果代数不等于当前值就丢弃，旧查询不会覆盖新结果。
  private var presenceGeneration: UInt64 = 0

  /// - Parameters:
  ///   - store: ssh-keys.json；测试传临时文件。
  ///   - credentials: 钥匙串；测试传内存替身。
  ///   - hostDirectory: 删除密钥时清理主机引用用。
  init(
    store: SSHVaultKeyStore = SSHVaultKeyStore(),
    credentials: any SSHCredentialStoring = SSHCredentialStore(),
    hostDirectory: @escaping () -> SSHHostDirectory
  ) {
    self.store = store
    self.credentials = credentials
    self.hostDirectory = hostDirectory
    keys = store.effectiveKeys
    reload()
  }

  /// 按 ID 查找。
  func key(_ id: UUID) -> SSHVaultKey? { keys.first { $0.id == id } }

  /// 按指纹查找（导入去重用）。
  func key(fingerprint: String) -> SSHVaultKey? { keys.first { $0.fingerprint == fingerprint } }

  /// 从磁盘重新加载并刷新钥匙串缓存；失败保留最后有效列表并记录原因。
  func reload() {
    do {
      keys = try store.load()
      loadError = nil
    } catch {
      loadError = String(describing: error)
    }
    refreshKeychainPresence()
  }

  /// 在后台查询每把密钥的私钥是否还在钥匙串里，结果回主线程按密钥 ID 写入 `keychainMissing`。
  ///
  /// 返回的任务供测试等待。查询期间目录可能变化：只保留仍在目录里的 ID，且只接受最新一次刷新的结果。
  @discardableResult
  func refreshKeychainPresence() -> Task<Void, Never> {
    presenceGeneration &+= 1
    let generation = presenceGeneration
    let ids = keys.map(\.id)
    let credentials = credentials
    return Task { @MainActor [weak self] in
      let missing = await Task.detached {
        Set(ids.filter { !credentials.hasVaultPrivateKey(id: $0) })
      }.value
      guard let self, generation == self.presenceGeneration else { return }
      let current = missing.intersection(self.keys.map(\.id))
      if current != self.keychainMissing { self.keychainMissing = current }
    }
  }

  /// 开始监听配置目录，外部编辑 ssh-keys.json 后自动重载。重复调用无副作用。
  func startWatching() {
    guard watcher == nil else { return }
    let directory = store.fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let watcher = FileSystemDirectoryWatcher(directory: directory)
      try watcher.start { [weak self] in self?.reload() }
      self.watcher = watcher
    } catch {
      loadError = String(describing: error)
    }
  }

  // MARK: - 写入

  /// 登记一把新密钥：先在后台把私钥写进钥匙串，再保存目录；目录保存失败就在后台删掉刚写的
  /// 钥匙串条目，不留下目录里看不到的孤儿私钥。
  ///
  /// 钥匙串写入期间目录可能被外部改动，所以保存时基于回到主线程后的最新列表追加。
  func add(_ key: SSHVaultKey, privateKey: String) async throws {
    let credentials = credentials
    do {
      try await Task.detached {
        try credentials.setVaultPrivateKey(privateKey, id: key.id, label: key.label)
      }.value
    } catch let error as SSHCredentialStoreError {
      throw SSHVaultKeyDirectoryError.keychain(error)
    }
    do {
      try commit(keys + [key])
    } catch {
      do {
        try await Task.detached { try credentials.deleteVaultPrivateKey(id: key.id) }.value
      } catch let cleanup as SSHCredentialStoreError {
        throw SSHVaultKeyDirectoryError.keychainCleanupFailed(cleanup)
      }
      throw error
    }
    refreshKeychainPresence()
  }

  /// 改名。钥匙串条目的显示名不跟着改：它只是提示，改它需要读写秘密。
  func rename(_ id: UUID, label: String) throws {
    guard let index = keys.firstIndex(where: { $0.id == id }) else {
      throw SSHVaultKeyDirectoryError.unknownKey
    }
    var next = keys
    next[index].label = label
    try commit(next)
  }

  /// 删除一把密钥：先从目录移除，再删钥匙串里的私钥，最后清掉主机（含默认项）对它的引用。
  ///
  /// 目录先删，broker 下一次同步就不再收到这把公钥；钥匙串删除在后台执行，失败时抛
  /// `keychainCleanupFailed`，目录与主机引用的清理照常完成。
  func remove(_ id: UUID) async throws {
    guard keys.contains(where: { $0.id == id }) else { throw SSHVaultKeyDirectoryError.unknownKey }
    try commit(keys.filter { $0.id != id })
    refreshKeychainPresence()
    var keychainFailure: SSHCredentialStoreError?
    let credentials = credentials
    do {
      try await Task.detached { try credentials.deleteVaultPrivateKey(id: id) }.value
    } catch let error as SSHCredentialStoreError {
      keychainFailure = error
    }
    try removeHostReferences(to: id)
    if let keychainFailure { throw SSHVaultKeyDirectoryError.keychainCleanupFailed(keychainFailure) }
  }

  /// 去掉所有主机对某把密钥的引用；列表变空时回到「继承」。
  private func removeHostReferences(to id: UUID) throws {
    let directory = hostDirectory()
    let current = directory.hosts
    let next = SSHVaultMigration.removingReferences(to: id, in: current)
    guard next != current else { return }
    try directory.store.save(next)
    directory.reload()
  }

  /// 保存目录并发布新值。
  private func commit(_ next: [SSHVaultKey]) throws {
    do {
      try store.save(next)
    } catch let error as SSHVaultKeyStoreError {
      throw SSHVaultKeyDirectoryError.store(error)
    }
    keys = store.effectiveKeys
    loadError = nil
  }
}
