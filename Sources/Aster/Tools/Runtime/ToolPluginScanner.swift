// 插件扫描：在后台读取内置原生、内置网页、用户插件与开发目录的清单，校验、算摘要、解析图标，
// 并按「内置 > 用户 > 开发」去重。只读磁盘，不改任何文件；调用方负责在后台调用并按代次回写。
import AsterCore
import Foundation

/// 扫描得到的一个插件。
struct ToolPluginRecord: Equatable, Sendable {
  let manifest: ToolManifest
  let source: ToolPluginSource
  /// 插件根目录（已解析符号链接）；内置原生工具没有目录。
  let directory: URL?
  /// 用户来源插件的文件摘要；其它来源为 nil。
  let digest: String?
  /// 插件图标的绝对路径（存在且在插件目录内才有）。
  let iconPath: String?
  /// 功能 code → 功能图标的绝对路径。
  let featureIconPaths: [String: String]
  /// 视图 id → 视图图标的绝对路径。
  var viewIconPaths: [String: String] = [:]
  /// 开发来源：`developmentFolders` 里登记的原字符串。设置页按它和登记列表逐字比对，
  /// 取消登记、监听变化也认它，不用重新解析过符号链接的 `directory`。
  var registeredPath: String?

  var id: String { manifest.id }

  /// 来自内置资源目录的插件（不是原生内置工具）；开发目录可以按 id 覆盖它。
  var isBuiltinFolderPlugin: Bool { source == .builtin && directory != nil }

  init(
    manifest: ToolManifest,
    source: ToolPluginSource,
    directory: URL?,
    digest: String?,
    iconPath: String? = nil,
    featureIconPaths: [String: String] = [:]
  ) {
    self.manifest = manifest
    self.source = source
    self.directory = directory
    self.digest = digest
    self.iconPath = iconPath
    self.featureIconPaths = featureIconPaths
  }
}

/// 一次扫描要看的位置。
struct ToolPluginScanLocations: Equatable, Sendable {
  /// `<Resources>/tools-builtin`；没有资源目录时为 nil。
  let builtinDirectory: URL?
  /// `<AppSupport>/Plugins`。
  let userDirectory: URL
  /// 登记的开发目录（绝对路径，按登记顺序）。
  let developmentFolders: [String]
}

/// 一次扫描的结果。
struct ToolPluginScanResult: Equatable, Sendable {
  var records: [ToolPluginRecord] = []
  var issues: [ToolPluginIssue] = []
}

/// 读取单个插件失败的原因。
struct ToolPluginLoadError: Error, Equatable, Sendable {
  /// 清单不合格（`detail` 是出错字段与原因）；否则是文件读取或摘要问题（`detail` 是完整说明）。
  let isManifestError: Bool
  let detail: String

  /// 扫描问题列表里给用户看的文字。
  var message: String { isManifestError ? L("清单无效：\(detail)") : detail }
}

/// 插件扫描的纯函数集合。全部在后台线程调用。
enum ToolPluginScanner {
  /// 依次扫描内置原生、内置网页、用户插件、开发目录；同 id 先到先得，后到的记一条冲突并跳过。
  /// 例外：开发目录里同 id 的插件覆盖内置网页 / 脚本插件（原生内置工具除外），改插件不用重新打包 App。
  static func scan(_ locations: ToolPluginScanLocations, fileManager: FileManager = .default) -> ToolPluginScanResult {
    var result = ToolPluginScanResult()
    var owners: [String: String] = [:]
    func add(_ record: ToolPluginRecord, path: String) {
      if record.source == .development,
        let index = result.records.firstIndex(where: { $0.id == record.id && $0.isBuiltinFolderPlugin })
      {
        result.records[index] = record
        owners[record.id] = path
        return
      }
      if let owner = owners[record.id] {
        result.issues.append(
          ToolPluginIssue(path: path, message: L("插件 id \(record.id) 已由 \(owner) 提供，这一份已跳过")))
        return
      }
      owners[record.id] = path
      result.records.append(record)
    }
    func load(_ folder: URL, source: ToolPluginSource, registeredPath: String? = nil) {
      let overridable = source == .development ? Self.overridableIDs(in: result.records) : []
      switch loadPlugin(at: folder, source: source, overridableBuiltinIDs: overridable, fileManager: fileManager) {
      case .success(var record):
        record.registeredPath = registeredPath
        add(record, path: registeredPath ?? record.directory?.path ?? folder.path)
      case .failure(let error):
        // 开发目录用登记的原字符串，其余与成功时的插件目录同一种写法（解析符号链接），设置页按路径对得上。
        let path = registeredPath ?? folder.standardizedFileURL.resolvingSymlinksInPath().path
        result.issues.append(ToolPluginIssue(path: path, message: error.message))
      }
    }

    add(
      ToolPluginRecord(manifest: BuiltinToolCatalog.manifest(), source: .builtin, directory: nil, digest: nil),
      path: L("Aster 内置工具"))
    if let builtin = locations.builtinDirectory {
      for folder in pluginFolders(in: builtin, fileManager: fileManager) { load(folder, source: .builtin) }
    }
    for folder in pluginFolders(in: locations.userDirectory, fileManager: fileManager) { load(folder, source: .user) }
    for path in locations.developmentFolders {
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        result.issues.append(ToolPluginIssue(path: path, message: L("开发目录不存在或不是文件夹")))
        continue
      }
      load(URL(fileURLWithPath: path, isDirectory: true), source: .development, registeredPath: path)
    }
    return result
  }

  /// 开发目录可以覆盖的内置插件 id：来自内置资源目录的插件（原生内置工具没有目录，不可覆盖）。
  static func overridableIDs(in records: [ToolPluginRecord]) -> Set<String> {
    Set(records.filter(\.isBuiltinFolderPlugin).map(\.id))
  }

  /// 读取并校验一个插件目录：清单（≤ 64 KiB）、用户来源的文件摘要、图标路径。
  /// `overridableBuiltinIDs`：开发来源允许使用的内置插件 id（覆盖内置插件时用）。
  static func loadPlugin(
    at folder: URL,
    source: ToolPluginSource,
    overridableBuiltinIDs: Set<String> = [],
    fileManager: FileManager = .default
  ) -> Result<ToolPluginRecord, ToolPluginLoadError> {
    let directory = folder.standardizedFileURL.resolvingSymlinksInPath()
    let data: Data
    do {
      data = try readManifest(in: directory)
    } catch {
      return .failure(error)
    }
    let manifest: ToolManifest
    do {
      manifest = try ToolManifest.decode(data, source: source, overridableBuiltinIDs: overridableBuiltinIDs)
    } catch let error as ToolManifestError {
      let detail = error.errorDescription ?? error.reason
      return .failure(ToolPluginLoadError(isManifestError: true, detail: detail))
    } catch {
      return .failure(ToolPluginLoadError(isManifestError: true, detail: error.localizedDescription))
    }
    var digest: String?
    if source == .user {
      do {
        digest = try ToolPluginDigest.compute(directory: directory, fileManager: fileManager)
      } catch let failure as ToolPluginDigest.Failure {
        return .failure(ToolPluginLoadError(isManifestError: false, detail: describe(failure)))
      } catch {
        return .failure(
          ToolPluginLoadError(isManifestError: false, detail: L("无法校验插件文件：\(error.localizedDescription)")))
      }
    }
    var featureIcons: [String: String] = [:]
    for feature in manifest.features {
      if let icon = feature.icon, let path = resolveIcon(icon, in: directory, fileManager: fileManager) {
        featureIcons[feature.code] = path
      }
    }
    var viewIcons: [String: String] = [:]
    for view in manifest.views {
      if let icon = view.icon, let path = resolveIcon(icon, in: directory, fileManager: fileManager) {
        viewIcons[view.id] = path
      }
    }
    var record = ToolPluginRecord(
      manifest: manifest, source: source, directory: directory, digest: digest,
      iconPath: manifest.icon.flatMap { resolveIcon($0, in: directory, fileManager: fileManager) },
      featureIconPaths: featureIcons)
    record.viewIconPaths = viewIcons
    return .success(record)
  }

  /// 开发目录的变化指纹：普通文件与子目录的相对路径、大小、修改时间。只用来发现变化，不做安全校验；
  /// 条目超过上限时只看前面一部分（与摘要的 2,000 个文件上限一致）。目录读不了返回 nil。
  static func fingerprint(of folder: String, fileManager: FileManager = .default) -> Int? {
    let root = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
    guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { return nil }
    var hasher = Hasher()
    hasher.combine(root.path)
    var count = 0
    for case let url as URL in enumerator {
      // Finder 浏览目录时会写 .DS_Store，不算插件变化。
      guard url.lastPathComponent != ".DS_Store" else { continue }
      count += 1
      guard count <= ToolPluginDigest.maximumFileCount else { break }
      hasher.combine(url.path)
      do {
        let values = try url.resourceValues(forKeys: Set(keys))
        hasher.combine(values.contentModificationDate)
        hasher.combine(values.fileSize)
      } catch {
        // 文件在遍历中途被删：路径已经记进指纹，下一轮自然不同。
        hasher.combine(-1)
      }
    }
    return hasher.finalize()
  }

  /// 目录下的插件候选：一层子目录（跟随符号链接），跳过隐藏项（安装用的 `.install-*` 临时目录），按名字排序。
  static func pluginFolders(in directory: URL, fileManager: FileManager = .default) -> [URL] {
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    } catch {
      // 目录还没建（从没装过插件）是正常情况。
      return []
    }
    return entries.filter { entry in
      var isDirectory: ObjCBool = false
      return fileManager.fileExists(atPath: entry.resolvingSymlinksInPath().path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// 读清单原文：必须是普通文件，先看大小再读，超过上限的文件不读进内存。
  private static func readManifest(in directory: URL) throws(ToolPluginLoadError) -> Data {
    let url = directory.appendingPathComponent(ToolManifest.fileName)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      throw ToolPluginLoadError(isManifestError: false, detail: L("缺少 aster-plugin.json"))
    }
    guard values.isRegularFile == true else {
      throw ToolPluginLoadError(isManifestError: false, detail: L("缺少 aster-plugin.json"))
    }
    guard (values.fileSize ?? 0) <= ToolManifest.maximumFileBytes else {
      throw ToolPluginLoadError(isManifestError: true, detail: "\(ToolManifest.fileName): " + L("清单文件太大"))
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw ToolPluginLoadError(isManifestError: false, detail: L("无法读取清单：\(error.localizedDescription)"))
    }
  }

  /// 图标路径：解析符号链接后仍在插件目录内且文件存在才返回绝对路径。
  private static func resolveIcon(_ relative: String, in directory: URL, fileManager: FileManager) -> String? {
    let candidate = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(directory.path + "/"), fileManager.fileExists(atPath: candidate.path) else {
      return nil
    }
    return candidate.path
  }

  /// 摘要失败的说明。
  private static func describe(_ failure: ToolPluginDigest.Failure) -> String {
    switch failure {
    case .unreadable(let path): L("无法读取插件文件：\(path)")
    case .symbolicLink(let path): L("插件里不能有符号链接：\(path)")
    case .tooManyFiles: L("插件文件太多（上限 2,000 个）")
    case .tooLarge: L("插件太大（上限 50 MiB）")
    }
  }
}
