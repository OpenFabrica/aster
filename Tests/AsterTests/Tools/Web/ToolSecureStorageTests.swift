// 加密存储：桥接读写、落盘不含明文、密钥丢失或被预埋时挪走旧文件、密文绑定插件 id；剪贴板机密标记。
import CryptoKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 建一个用内存密钥库的桥接，返回它、密钥库、假系统能力与插件目录。
@MainActor
private func makeSecureBridge(
  keyStore: InMemoryToolSecureStorageKeyStore = InMemoryToolSecureStorageKeyStore(),
  permissions: [ToolPermission] = [],
  directory: URL? = nil
) throws -> (ToolBridge, InMemoryToolSecureStorageKeyStore, FakeToolBridgeServices, URL) {
  let directory = try directory ?? makeTemporaryPluginDirectory()
  let services = FakeToolBridgeServices()
  let bridge = ToolBridge(
    plugin: makeWebToolPlugin(directory: directory, permissions: permissions), services: services,
    secureKeyStore: keyStore)
  bridge.delegate = FakeToolBridgeDelegate(request: makeWebToolRequest())
  return (bridge, keyStore, services, directory)
}

/// 插件数据目录里的加密文件与留底文件。
private func secureFiles(_ directory: URL) -> (file: URL, quarantine: URL) {
  let data = directory.appendingPathComponent("data", isDirectory: true)
  return (
    data.appendingPathComponent(ToolPluginSecureStorage.fileName),
    data.appendingPathComponent(ToolPluginSecureStorage.quarantineFileName)
  )
}

@Test("加密存储读写删与 keys；文件以魔数开头、不含明文，密钥按插件 id 存进密钥库")
@MainActor
func secureStorageRoundTripEncryptsOnDisk() async throws {
  let (bridge, keyStore, _, directory) = try makeSecureBridge()
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(await callBridge(bridge, "secureStorage.get", ["key": "history"]).json == "null")
  #expect(keyStore.keys.isEmpty, "只读不建密钥")
  let history: [Any] = [["password": "S3cret-PLAINTEXT", "site": "example.com"]]
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "history", "value": history]).error == nil)
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "a", "value": 1]).error == nil)
  #expect(
    await callBridge(bridge, "secureStorage.get", ["key": "history"]).json
      == #"[{"password":"S3cret-PLAINTEXT","site":"example.com"}]"#)
  #expect(await callBridge(bridge, "secureStorage.keys").json == #"["a","history"]"#)
  #expect(await callBridge(bridge, "secureStorage.remove", ["key": "a"]).error == nil)
  #expect(await callBridge(bridge, "secureStorage.keys").json == #"["history"]"#)

  let data = try Data(contentsOf: secureFiles(directory).file)
  #expect(data.starts(with: ToolPluginSecureStorage.magic))
  #expect(data.range(of: Data("PLAINTEXT".utf8)) == nil)
  #expect(data.range(of: Data("example.com".utf8)) == nil)
  #expect(keyStore.keys["com.example.webtest"]?.count == 32)
  // 普通存储不受影响。
  #expect(await callBridge(bridge, "storage.keys").json == "[]")
}

@Test("新桥接（重启后）用密钥库里的同一把密钥读回内容")
@MainActor
func secureStoragePersistsAcrossInstances() async throws {
  let keyStore = InMemoryToolSecureStorageKeyStore()
  let directory = try makeTemporaryPluginDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    let (bridge, _, _, _) = try makeSecureBridge(keyStore: keyStore, directory: directory)
    #expect(await callBridge(bridge, "secureStorage.set", ["key": "k", "value": "v"]).error == nil)
  }
  // 直接用新实例解密，绕过进程内共享缓存。
  let storage = ToolPluginSecureStorage(
    directory: directory.appendingPathComponent("data"), pluginID: "com.example.webtest", keyStore: keyStore)
  #expect(try await storage.value(forKey: "k") == "v")
}

@Test("密钥丢失：旧文件改名留底，按空存储继续，之后的写入用新密钥")
@MainActor
func secureStorageQuarantinesFileWhenKeyIsMissing() async throws {
  let directory = try makeTemporaryPluginDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = secureFiles(directory)
  let oldKey = SymmetricKey(size: .bits256)
  try FileManager.default.createDirectory(at: files.file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try ToolPluginSecureStorage.encrypt(Data(#"{"k":"old"}"#.utf8), key: oldKey, pluginID: "com.example.webtest")
    .write(to: files.file)

  let (bridge, keyStore, _, _) = try makeSecureBridge(directory: directory)
  #expect(await callBridge(bridge, "secureStorage.get", ["key": "k"]).json == "null")
  #expect(FileManager.default.fileExists(atPath: files.quarantine.path))
  #expect(!FileManager.default.fileExists(atPath: files.file.path))
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "k", "value": "new"]).error == nil)
  #expect(keyStore.keys["com.example.webtest"] != oldKey.withUnsafeBytes { Data($0) })
}

@Test("钥匙串条目不可信：不用预埋的密钥，旧文件留底，新写入用 Aster 自己新建的密钥")
@MainActor
func secureStorageRejectsPlantedKey() async throws {
  let directory = try makeTemporaryPluginDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = secureFiles(directory)
  let planted = SymmetricKey(size: .bits256)
  let plantedData = planted.withUnsafeBytes { Data($0) }
  try FileManager.default.createDirectory(at: files.file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try ToolPluginSecureStorage.encrypt(Data(#"{"k":"planted"}"#.utf8), key: planted, pluginID: "com.example.webtest")
    .write(to: files.file)
  let keyStore = InMemoryToolSecureStorageKeyStore()
  keyStore.plantUntrustedKey(plantedData, pluginID: "com.example.webtest")

  let (bridge, _, _, _) = try makeSecureBridge(keyStore: keyStore, directory: directory)
  #expect(await callBridge(bridge, "secureStorage.get", ["key": "k"]).json == "null")
  #expect(FileManager.default.fileExists(atPath: files.quarantine.path))
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "k", "value": "mine"]).error == nil)
  let current = try #require(keyStore.keys["com.example.webtest"])
  #expect(current != plantedData)
  let sealed = try Data(contentsOf: files.file)
  #expect(ToolPluginSecureStorage.decrypt(sealed, key: planted, pluginID: "com.example.webtest") == nil)
}

@Test("密文绑定插件 id 与魔数：换插件 id、改坏魔数或篡改密文都解不开")
func secureStorageCiphertextIsBoundToPlugin() throws {
  let key = SymmetricKey(size: .bits256)
  let sealed = try ToolPluginSecureStorage.encrypt(Data(#"{"a":1}"#.utf8), key: key, pluginID: "aster.password")
  #expect(ToolPluginSecureStorage.decrypt(sealed, key: key, pluginID: "aster.password") == ["a": 1])
  #expect(ToolPluginSecureStorage.decrypt(sealed, key: key, pluginID: "com.example.other") == nil)
  var badMagic = sealed
  badMagic[0] = 0
  #expect(ToolPluginSecureStorage.decrypt(badMagic, key: key, pluginID: "aster.password") == nil)
  var tampered = sealed
  tampered[tampered.count - 1] ^= 0xFF
  #expect(ToolPluginSecureStorage.decrypt(tampered, key: key, pluginID: "aster.password") == nil)
}

@Test("加密存储的 key 与总量上限和普通存储一致")
@MainActor
func secureStorageEnforcesLimits() async throws {
  let (bridge, _, _, directory) = try makeSecureBridge()
  defer { try? FileManager.default.removeItem(at: directory) }

  let longKey = String(repeating: "k", count: ToolBridgeProtocol.maximumStorageKeyBytes + 1)
  #expect(await callBridge(bridge, "secureStorage.set", ["key": longKey, "value": 1]).errorCode == "payload_too_large")
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "", "value": 1]).errorCode == "invalid_params")
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "novalue"]).errorCode == "invalid_params")
  let chunk = String(repeating: "x", count: 1_900_000)
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "one", "value": chunk]).error == nil)
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "two", "value": chunk]).error == nil)
  #expect(await callBridge(bridge, "secureStorage.set", ["key": "three", "value": chunk]).errorCode == "payload_too_large")
  #expect(await callBridge(bridge, "secureStorage.keys").json == #"["one","two"]"#)
}

@Test("clipboard.writeText 的 concealed 只认布尔值，缺省不标机密")
@MainActor
func clipboardWriteSupportsConcealedFlag() async throws {
  let (bridge, _, services, directory) = try makeSecureBridge(permissions: [.clipboardWrite])
  defer { try? FileManager.default.removeItem(at: directory) }

  #expect(await callBridge(bridge, "clipboard.writeText", ["text": "plain"]).error == nil)
  #expect(services.clipboard == "plain")
  #expect(!services.clipboardConcealed)
  #expect(await callBridge(bridge, "clipboard.writeText", ["text": "pw", "concealed": true]).error == nil)
  #expect(services.clipboard == "pw")
  #expect(services.clipboardConcealed)
  #expect(
    await callBridge(bridge, "clipboard.writeText", ["text": "x", "concealed": "yes"]).errorCode == "invalid_params")
}
