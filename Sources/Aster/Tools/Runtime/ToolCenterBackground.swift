// 工具中心的后台操作：扫描、读取待安装文件夹、复制安装、算摘要、移到废纸篓、删目录。都是阻塞的磁盘操作，
// 用 @concurrent 放到后台执行；结果由 `ToolCenter` 在主线程按发起时的代次回写。
import AsterCore
import Foundation

/// `ToolCenter` 的后台磁盘操作。失败统一抛 `ToolCenterError`。
enum ToolCenterBackground {
  /// 后台扫描全部来源。
  @concurrent
  static func scan(_ locations: ToolPluginScanLocations) async -> ToolPluginScanResult {
    ToolPluginScanner.scan(locations)
  }

  /// 后台读取并校验一个待安装或待登记的文件夹。
  @concurrent
  static func inspect(_ folder: URL, source: ToolPluginSource) async throws -> ToolPluginRecord {
    switch ToolPluginScanner.loadPlugin(at: folder, source: source) {
    case .success(let record): return record
    case .failure(let error) where error.isManifestError: throw ToolCenterError.invalidManifest(error.detail)
    case .failure(let error): throw ToolCenterError.fileOperationFailed(error.detail)
    }
  }

  /// 后台复制安装。
  @concurrent
  static func install(_ source: URL, id: String, digest: String, into directory: URL) async throws {
    _ = try ToolPluginFileOperations.install(from: source, id: id, expectedDigest: digest, into: directory)
  }

  /// 后台算插件目录摘要；失败（出现符号链接、超限）返回 nil，调用方按「和授权时不同」处理。
  @concurrent
  static func digest(of directory: URL) async -> String? {
    do {
      return try ToolPluginDigest.compute(directory: directory)
    } catch {
      return nil
    }
  }

  /// 后台把插件目录移到废纸篓。
  @concurrent
  static func moveToTrash(_ url: URL, using move: @Sendable (URL) throws -> Void) async throws {
    do {
      try move(url)
    } catch {
      throw ToolCenterError.fileOperationFailed(error.localizedDescription)
    }
  }

  /// 后台删除目录（不存在不算错）。
  @concurrent
  static func removeDirectory(_ url: URL) async throws {
    try ToolPluginFileOperations.removeDirectory(url)
  }

  /// 后台删除插件加密存储的密钥。数据目录已经删掉，密钥留着也解不开任何东西，所以失败只记诊断、不打断卸载。
  @concurrent
  static func removeSecureStorageKey(pluginID: String, from store: any ToolSecureStorageKeyStoring) async {
    do {
      try store.deleteKey(pluginID: pluginID)
    } catch {
      DiagnosticsCenter.shared.record(
        "tools.secure_storage_key_cleanup_failed", level: .warning, category: .storage, error: error)
    }
  }

  /// 后台建插件目录并清掉上次安装中途留下的临时目录。建不了时扫描照常进行（目录为空）。
  @concurrent
  static func preparePluginsDirectory(_ directory: URL) async {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      DiagnosticsCenter.shared.record("tools.plugins_directory_failed", level: .warning, category: .storage, error: error)
    }
    ToolPluginFileOperations.removeStaleStaging(in: directory)
  }
}
