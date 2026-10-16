// 保险库动作服务与「密钥」页测试共用的夹具：临时目录、内存钥匙串、假 `aster-ssh keys` 与可控弹窗。
import AppKit
import AsterCore
import Foundation

@testable import Aster

/// 服务测试的记录与可控弹窗。
@MainActor
final class VaultActionsRecorder {
  var toasts: [(text: String, isError: Bool)] = []
  var pasteboard: [String] = []
  var chosenFile: URL?
  /// 非 nil 时选择文件会挂起，直到测试调用 `releaseChooser`。
  var chooserGate: CheckedContinuation<URL?, Never>?
  var holdsChooser = false
  var confirmsDeleteOriginal = true

  /// 放行挂起的文件选择。
  func releaseChooser() {
    chooserGate?.resume(returning: chosenFile)
    chooserGate = nil
  }
}

/// 测试夹具：临时 hosts.json / ssh-keys.json、内存钥匙串、假 `aster-ssh keys` 与可控弹窗。
@MainActor
struct VaultActionsFixture {
  let root: URL
  let actions: SSHVaultKeyActions
  let credentials = InMemoryVaultCredentials()
  let recorder = VaultActionsRecorder()
  var keys: SSHVaultKeyDirectory { actions.directory }
  var hosts: SSHHostDirectory { actions.hosts }

  init(
    hosts: [SSHHostProfile] = [], tool: FakeVaultKeyTool = FakeVaultKeyTool(), engine: SSHEngine = .native
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsterVaultActions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hostStore = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
    try hostStore.save([.emptyDefaults()] + hosts)
    let hostDirectory = SSHHostDirectory(store: hostStore)
    let vault = SSHVaultKeyDirectory(
      store: SSHVaultKeyStore(fileURL: root.appendingPathComponent("ssh-keys.json")),
      credentials: credentials, hostDirectory: { hostDirectory })
    let recorder = recorder
    actions = SSHVaultKeyActions(
      dependencies: .init(
        directory: vault,
        tool: { tool },
        chooseKeyFile: { _ in
          guard recorder.holdsChooser else { return recorder.chosenFile }
          return await withCheckedContinuation { recorder.chooserGate = $0 }
        },
        readKeyFile: SSHVaultKeyActions.readKeyFile,
        promptPassphrase: { _, _ in nil },
        copyToPasteboard: { recorder.pasteboard.append($0) },
        confirmDeleteOriginal: { _, _ in recorder.confirmsDeleteOriginal },
        configListing: { SSHConfigListing() },
        engine: { engine },
        homeDirectory: root.path,
        localUser: "tester"),
      hosts: hostDirectory)
    actions.toast = { recorder.toasts.append(($0, $1)) }
  }

  /// 直接登记一把密钥（不经导入流程）。
  func addKey(_ seed: String, label: String, importedFrom: String? = nil) async throws -> SSHVaultKey {
    let material = fakeVaultMaterial(seed)
    let key = SSHVaultKey(
      label: label, algorithm: material.algorithm, fingerprint: material.fingerprint,
      publicKey: material.publicKey, origin: importedFrom == nil ? .generated : .imported,
      importedFrom: importedFrom)
    try await keys.add(key, privateKey: material.privateKey)
    return key
  }

  /// 在临时家目录写一个文件，缺的目录自动创建。
  func writeFile(_ name: String, _ text: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
