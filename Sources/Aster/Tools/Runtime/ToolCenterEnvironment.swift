// 工具中心依赖的外部环境：数据与资源目录、安装确认、删除操作、监听开关与内置清单翻译。App 用 `live()`，
// 测试注入临时目录与假实现。
import AppKit
import AsterCore
import WebKit

/// 工具中心依赖的外部环境；测试注入临时目录、假确认器与假的删除操作。
@MainActor
struct ToolCenterEnvironment {
  /// `<AppSupport>`：`Plugins/`、`PluginData/` 与 `tools-state.json` 都在它下面。
  var applicationSupportDirectory: URL
  /// App 资源目录（内置网页工具在 `tools-builtin/`）；nil 表示没有内置网页工具。
  var resourcesDirectory: URL?
  /// 安装确认。
  var approver: any ToolInstallApproving
  /// 把用户插件目录移到废纸篓（后台调用）。
  var moveToTrash: @Sendable (URL) throws -> Void
  /// 删除插件的 WebKit 数据存储；还在使用时抛错。
  var removeWebsiteData: @MainActor (UUID) async throws -> Void
  /// 是否监听插件目录、轮询开发目录（测试关掉，改为手动 `reload`）。
  var watchesFileSystem: Bool
  /// 使用记录写盘的去抖间隔。
  var usageSaveDelay: Duration
  /// 原生工具用的终端主题与字体。
  var terminalStyle: @MainActor () -> ToolTerminalStyle
  /// 内置网页插件清单文案的翻译：简体中文原文 → 当前界面语言；源语言下原样返回。
  var translateBuiltinText: (String) -> String
  /// 网页工具加密存储的密钥；卸载时删除。默认内存实现，测试不碰钥匙串；`live()` 用真实钥匙串。
  var secureKeyStore: any ToolSecureStorageKeyStoring = InMemoryToolSecureStorageKeyStore()

  /// App 运行时的真实环境。
  static func live() -> ToolCenterEnvironment {
    ToolCenterEnvironment(
      applicationSupportDirectory: AsterAppIdentity.current.applicationSupportDirectory(),
      resourcesDirectory: AsterResourceLocations.resourcesDirectory(),
      approver: ToolInstallSheetApprover(),
      moveToTrash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
      removeWebsiteData: { identifier in
        // 进程里还没建过任何 WebKit 对象时，WebKit 删除数据存储会派发到未初始化的主 RunLoop 而崩溃；
        // 先取一次默认数据存储完成初始化。
        _ = WKWebsiteDataStore.default()
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
      },
      watchesFileSystem: true,
      usageSaveDelay: .seconds(2),
      terminalStyle: { ToolTerminalStyle.current() },
      translateBuiltinText: { L(String.LocalizationValue($0)) },
      secureKeyStore: ToolSecureStorageKeychain())
  }
}
