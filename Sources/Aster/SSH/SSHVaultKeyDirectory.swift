import AsterCore
import Combine
import Foundation

// 私钥保险库的 App 侧唯一权威入口：读写 ssh-keys.json、监听外部修改、发布变化，
// 并保证目录与钥匙串的一致：私钥先进钥匙串再登记目录，删除时目录、钥匙串、主机引用一起清理。
// 设置页与 broker 同步都从这里读，不各自持有副本。

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

  let store: SSHVaultKeyStore
  let credentials: any SSHCredentialStoring
  private let hostDirectory: () -> SSHHostDirectory
  private var watcher: FileSystemDirectoryWatcher?

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

  /// 从磁盘重新加载；失败保留最后有效列表并记录原因。
  func reload() {
    do {
      keys = try store.load()
      loadError = nil
    } catch {
      loadError = String(describing: error)
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

  /// 登记一把新密钥：先把私钥写进钥匙串，再保存目录；目录保存失败就删掉刚写的钥匙串条目，
  /// 不留下目录里看不到的孤儿私钥。
  func add(_ key: SSHVaultKey, privateKey: String) throws {
    do {
      try credentials.setVaultPrivateKey(privateKey, id: key.id, label: key.label)
    } catch let error as SSHCredentialStoreError {
      throw SSHVaultKeyDirectoryError.keychain(error)
    }
    do {
      try commit(keys + [key])
    } catch {
      do {
        try credentials.deleteVaultPrivateKey(id: key.id)
      } catch let cleanup as SSHCredentialStoreError {
        throw SSHVaultKeyDirectoryError.keychainCleanupFailed(cleanup)
      }
      throw error
    }
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
  /// 目录先删，broker 下一次同步就不再收到这把公钥；钥匙串删除失败时抛
  /// `keychainCleanupFailed`，目录与主机引用的清理照常完成。
  func remove(_ id: UUID) throws {
    guard keys.contains(where: { $0.id == id }) else { throw SSHVaultKeyDirectoryError.unknownKey }
    try commit(keys.filter { $0.id != id })
    var keychainFailure: SSHCredentialStoreError?
    do {
      try credentials.deleteVaultPrivateKey(id: id)
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
