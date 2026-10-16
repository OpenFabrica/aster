// SSHAuthCoordinator 的保险库私钥请求：只从钥匙串作答、从不弹窗、不进 pending、被拒不删除。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 任何弹窗都记一笔：保险库请求一次都不该弹。
@MainActor
private final class CountingPresenter: SSHAuthPresenting {
  private(set) var prompts = 0

  func promptSecret(_ prompt: SSHSecretPrompt) async -> SSHSecretPromptResponse? {
    prompts += 1
    return SSHSecretPromptResponse(secret: "typed", remember: true)
  }
  func promptKeyboardInteractive(_ prompt: SSHKeyboardInteractivePrompt) async -> [String]? {
    prompts += 1
    return nil
  }
  func confirmHostKey(_ request: SSHHostKeyRequest) async -> Bool {
    prompts += 1
    return false
  }
}

/// 一次保险库私钥请求。
private func vaultRequest(_ keyID: UUID?, id: String = "v1", interactive: Bool = false) -> SSHAuthRequest {
  SSHAuthRequest(
    id: id, endpoint: "deploy@10.0.0.5:22", kind: .privateKey, attempt: 1, interactive: interactive,
    vaultKeyID: keyID)
}

@Test("保险库私钥：非交互请求也从钥匙串作答，不弹窗、不进 pending")
@MainActor
func sshAuthCoordinatorAnswersVaultKeyFromKeychain() async throws {
  let store = InMemoryVaultCredentials()
  let keyID = UUID()
  try store.setVaultPrivateKey("PEM-TEXT", id: keyID, label: "k")
  let presenter = CountingPresenter()
  let coordinator = SSHAuthCoordinator(
    store: store, presenter: presenter, vaultKeyExists: { $0 == keyID })

  let answer = await coordinator.answer(vaultRequest(keyID))
  #expect(answer == .authAnswer(id: "v1", secret: "PEM-TEXT", responses: nil))
  #expect(presenter.prompts == 0)
  #expect(coordinator.pendingCount == 0)
}

@Test("保险库私钥：目录里没有的 ID、缺 ID、钥匙串缺条目都回 null 跳过")
@MainActor
func sshAuthCoordinatorSkipsUnknownVaultKeys() async throws {
  let store = InMemoryVaultCredentials()
  let known = UUID()
  let stranger = UUID()
  // 钥匙串里有，但目录里没有：不能凭 broker 给的任意 ID 读钥匙串。
  try store.setVaultPrivateKey("STRANGER", id: stranger, label: "x")
  let presenter = CountingPresenter()
  let coordinator = SSHAuthCoordinator(
    store: store, presenter: presenter, vaultKeyExists: { $0 == known })

  let skip = { (id: String) in SSHBrokerCommand.authAnswer(id: id, secret: nil, responses: nil) }
  #expect(await coordinator.answer(vaultRequest(stranger, id: "a")) == skip("a"))
  #expect(await coordinator.answer(vaultRequest(nil, id: "b")) == skip("b"))
  #expect(await coordinator.answer(vaultRequest(known, id: "c", interactive: true)) == skip("c"))
  #expect(presenter.prompts == 0)
}

@Test("保险库私钥被服务器拒绝时不删除钥匙串条目")
@MainActor
func sshAuthCoordinatorKeepsVaultKeyOnRejection() async throws {
  let store = InMemoryVaultCredentials()
  let keyID = UUID()
  try store.setVaultPrivateKey("PEM-TEXT", id: keyID, label: "k")
  let coordinator = SSHAuthCoordinator(
    store: store, presenter: CountingPresenter(), vaultKeyExists: { _ in true })

  _ = await coordinator.answer(vaultRequest(keyID))
  let task = coordinator.settle(id: "v1", accepted: false)
  #expect(task == nil)
  #expect(store.hasVaultPrivateKey(id: keyID))
}
