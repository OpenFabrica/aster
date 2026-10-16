import AppKit
import AsterCore
import Foundation

// 「密钥」子页的动作分发：解析网页 payload，调用 `SSHVaultKeyActions` 对应动作，
// 以 `complete(succeeded)` 结束，SettingsViewController 据此给网页发回执。

extension SettingsSSHKeysBridge {
  /// 分发一个 `hosts.keys.` 前缀的动作。未知动作或参数无效时 toast 报错并回执失败。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) {
    let actions = actions
    switch action {
    case "hosts.keys.import":
      run(complete) { await actions.importKey() }
    case "hosts.keys.generate":
      guard let label = payload["label"] as? String else { return reject(complete) }
      let comment = payload["comment"] as? String ?? ""
      run(complete) { await actions.generate(label: label, comment: comment) }
    case "hosts.keys.rename":
      guard let id = keyID(payload), let label = payload["label"] as? String else { return reject(complete) }
      complete(actions.rename(id, label: label))
    case "hosts.keys.copyPublicKey":
      guard let id = keyID(payload) else { return reject(complete) }
      complete(actions.copyPublicKey(id))
    case "hosts.keys.delete":
      guard let id = keyID(payload) else { return reject(complete) }
      run(complete) { await actions.delete(id) }
    case "hosts.keys.migrateReferences":
      guard let id = keyID(payload) else { return reject(complete) }
      complete(actions.migrateReferences(id))
    case "hosts.keys.deleteOriginal":
      guard let id = keyID(payload) else { return reject(complete) }
      run(complete) { await actions.deleteOriginal(id) }
    default:
      toast(L("“\(action)”尚无可用的 macOS 操作"), true)
      complete(false)
    }
  }

  /// payload 里的 `id`；缺失或不是 UUID 返回 nil。
  private func keyID(_ payload: [String: Any]) -> UUID? {
    (payload["id"] as? String).flatMap(UUID.init(uuidString:))
  }

  /// 参数无效：提示并回执失败。
  private func reject(_ complete: (Bool) -> Void) {
    toast(SSHVaultKeyActionError.invalidPayload.message, true)
    complete(false)
  }

  /// 在主线程任务里跑一个异步动作，结束后回执。
  private func run(_ complete: @escaping (Bool) -> Void, _ work: @escaping @MainActor () async -> Bool) {
    Task { @MainActor in complete(await work()) }
  }
}
