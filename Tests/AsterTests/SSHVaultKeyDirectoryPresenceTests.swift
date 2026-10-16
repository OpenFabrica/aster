import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 保险库目录的钥匙串 I/O 不占主线程：增删与「钥匙串中缺失」缓存都在后台查询，快照只读缓存。

@Test("导入、生成、删除与快照都不在主线程读写钥匙串")
@MainActor
func sshVaultKeychainIOStaysOffMainThread() async throws {
  let fixture = try KeysBridgeFixture(
    tool: FakeVaultKeyTool(
      entries: ["PLAIN": .init(material: fakeVaultMaterial("p"))], generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  await fixture.keys.refreshKeychainPresence().value
  _ = fixture.credentials.takeMainThreadVaultCalls()

  #expect(await fixture.perform("hosts.keys.generate", ["label": "k"]) == true)
  fixture.recorder.chosenFile = try fixture.writeKeyFile(".ssh/id_ed25519", "PLAIN")
  #expect(await fixture.perform("hosts.keys.import") == true)
  #expect(fixture.keys.keys.count == 2)
  _ = fixture.hostsBridge.snapshot()
  let generated = try #require(fixture.keys.keys.first { $0.origin == .generated })
  #expect(await fixture.perform("hosts.keys.delete", ["id": generated.id.uuidString]) == true)
  await fixture.keys.refreshKeychainPresence().value
  _ = fixture.hostsBridge.snapshot()

  #expect(fixture.credentials.takeMainThreadVaultCalls() == [])
}

@Test("钥匙串缺失缓存：外部删掉私钥后刷新可见；删除密钥后不再列出；新增的密钥不算缺失")
@MainActor
func sshVaultKeychainMissingCacheRefreshes() async throws {
  let fixture = try KeysBridgeFixture(tool: FakeVaultKeyTool(generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  #expect(await fixture.perform("hosts.keys.generate", ["label": "k"]) == true)
  let key = try #require(fixture.keys.keys.first)
  await fixture.keys.refreshKeychainPresence().value
  #expect(fixture.keys.keychainMissing.isEmpty)

  // 在「钥匙串访问」里手动删掉：刷新之前快照仍读旧缓存，刷新之后标记缺失。
  try fixture.credentials.deleteVaultPrivateKey(id: key.id)
  #expect(fixture.keys.keychainMissing.isEmpty)
  await fixture.keys.refreshKeychainPresence().value
  #expect(fixture.keys.keychainMissing == [key.id])
  let rows = try #require(fixture.hostsBridge.snapshot()["vaultKeys"] as? [[String: Any]])
  #expect(rows.first?["keychainMissing"] as? Bool == true)

  // 目录重新加载（外部修改 ssh-keys.json 走的路径）也会刷新。
  try fixture.credentials.setVaultPrivateKey("x", id: key.id, label: "k")
  fixture.keys.reload()
  await fixture.keys.refreshKeychainPresence().value
  #expect(fixture.keys.keychainMissing.isEmpty)

  // 删除密钥后缓存里不再有它。
  try fixture.credentials.deleteVaultPrivateKey(id: key.id)
  await fixture.keys.refreshKeychainPresence().value
  #expect(await fixture.perform("hosts.keys.delete", ["id": key.id.uuidString]) == true)
  await fixture.keys.refreshKeychainPresence().value
  #expect(fixture.keys.keychainMissing.isEmpty)
}

@Test("钥匙串缺失缓存：较早发起的刷新晚回来时不覆盖较新的结果")
@MainActor
func sshVaultKeychainMissingIgnoresStaleRefresh() async throws {
  let fixture = try KeysBridgeFixture(tool: FakeVaultKeyTool(generated: fakeVaultMaterial("gen")))
  defer { fixture.cleanUp() }
  #expect(await fixture.perform("hosts.keys.generate", ["label": "k"]) == true)
  let key = try #require(fixture.keys.keys.first)
  try fixture.credentials.deleteVaultPrivateKey(id: key.id)
  // 第一次刷新还没回到主线程时就发起第二次：第一次的结果按代数丢弃，最终只认第二次。
  let stale = fixture.keys.refreshKeychainPresence()
  try fixture.credentials.setVaultPrivateKey("x", id: key.id, label: "k")
  let fresh = fixture.keys.refreshKeychainPresence()
  await stale.value
  await fresh.value
  #expect(fixture.keys.keychainMissing.isEmpty)
}
