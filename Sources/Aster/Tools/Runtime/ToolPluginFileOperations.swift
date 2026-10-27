// 插件安装与卸载的磁盘操作：复制到插件目录内的临时目录、核对摘要、原子改名；删除插件数据。
// 全部是同步阻塞调用，只能在后台执行。
import AsterCore
import Darwin
import Foundation

/// 安装、卸载用到的文件操作。失败抛 `ToolCenterError`。
enum ToolPluginFileOperations {
  /// 安装用的临时目录前缀；扫描跳过隐藏项，所以半途留下的临时目录不会被当成插件。
  static let stagingPrefix = ".install-"

  /// 把 `source` 安装成 `<pluginsDirectory>/<id>`：先整份复制到同目录下的临时目录，摘要必须等于用户确认时的
  /// `expectedDigest`（防止确认之后、复制之前文件被换掉），再用 RENAME_EXCL 原子改名，目标已存在就失败。
  /// 返回安装后的目录。
  static func install(
    from source: URL,
    id: String,
    expectedDigest: String,
    into pluginsDirectory: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    // id 已经过清单校验；这里再挡一次，保证它只能落在插件目录的一层子目录里。
    guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw ToolCenterError.invalidManifest(id) }
    let destination = pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    let staging = pluginsDirectory.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
    do {
      try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    } catch {
      throw ToolCenterError.fileOperationFailed(error.localizedDescription)
    }
    guard !fileManager.fileExists(atPath: destination.path) else { throw ToolCenterError.alreadyInstalled(id) }
    var installed = false
    defer {
      if !installed { removeIfPresent(staging, fileManager: fileManager) }
    }
    do {
      try fileManager.copyItem(at: source, to: staging)
    } catch {
      throw ToolCenterError.fileOperationFailed(error.localizedDescription)
    }
    let digest: String
    do {
      digest = try ToolPluginDigest.compute(directory: staging, fileManager: fileManager)
    } catch {
      throw ToolCenterError.fileOperationFailed(L("无法校验复制后的插件文件"))
    }
    guard digest == expectedDigest else {
      throw ToolCenterError.fileOperationFailed(L("插件文件在安装过程中被改动了，请重试"))
    }
    if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
      let code = errno
      if code == EEXIST { throw ToolCenterError.alreadyInstalled(id) }
      throw ToolCenterError.fileOperationFailed(String(cString: strerror(code)))
    }
    installed = true
    return destination
  }

  /// 删除目录（不存在不算错）。插件数据删不掉时抛错，调用方告诉用户。
  static func removeDirectory(_ url: URL, fileManager: FileManager = .default) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      throw ToolCenterError.fileOperationFailed(error.localizedDescription)
    }
  }

  /// 清掉上次安装中途退出留下的临时目录。
  static func removeStaleStaging(in pluginsDirectory: URL, fileManager: FileManager = .default) {
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: nil)
    } catch {
      return  // 插件目录还不存在：没有可清理的
    }
    for entry in entries where entry.lastPathComponent.hasPrefix(stagingPrefix) {
      removeIfPresent(entry, fileManager: fileManager)
    }
  }

  /// 尽力删除；失败只记诊断（临时目录是隐藏项，不影响扫描，下次启动再清）。
  private static func removeIfPresent(_ url: URL, fileManager: FileManager) {
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      try fileManager.removeItem(at: url)
    } catch {
      DiagnosticsCenter.shared.record(
        "tools.staging_cleanup_failed", level: .warning, category: .storage, error: error)
    }
  }
}
