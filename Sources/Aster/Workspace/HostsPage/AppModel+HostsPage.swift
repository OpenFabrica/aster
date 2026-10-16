import AppKit
import AsterCore
import Foundation

// 侧栏「主机」页的显隐与主机动作。页面状态只是本窗口内容区显示什么，不持久化；
// 主机数据的唯一权威仍是 `SSHHostDirectory`，这里只调用它与已有的 SSH 打开入口。
// 单台主机的复制、删除与编辑动作在 `HostsPageViewController`（使用页面注入的目录与依赖）。

extension AppModel {
  /// 在内容区显示主机页。命令面板与侧栏「主机」行共用。
  func presentHostsPage() {
    // 浮层与主机页抢同一块注意力：打开主机页时收起它们，避免搜索框被盖住。
    if isPalettePresented { isPalettePresented = false }
    if isOpenQuicklyPresented { isOpenQuicklyPresented = false }
    if !isHostsPagePresented { isHostsPagePresented = true }
  }

  /// 打开主机页并切到指定子页（例如从其它入口直达「密钥」或「已知主机」）。
  func presentHostsPage(section: HostsHubSection) {
    if hostsPageSection != section { hostsPageSection = section }
    presentHostsPage()
  }

  /// 打开主机页并打开指定主机的原生编辑面板。主机已不存在时面板不打开，主机页停在列表并提示。
  func showHostEditor(hostID: UUID) {
    showHostEditor(.edit(hostID))
  }

  /// 打开主机页的「主机」子页并请求打开编辑面板。
  ///
  /// 请求先记在 `pendingHostEditor`，由 `HostsPageViewController.pageDidAppear` 消费：主机页
  /// 尚未显示、正显示别的子页或已经显示时都走同一条路径。
  func showHostEditor(_ mode: HostEditorMode) {
    pendingHostEditor = mode
    // 主机页已显示在「主机」子页时下面的属性都不变、不会触发刷新；主动发一次变化，
    // 让工作区重建内容区并调用 `pageDidAppear`。
    objectWillChange.send()
    presentHostsPage(section: .hosts)
  }

  /// 关闭主机页、回到当前标签的终端。
  func dismissHostsPage() {
    if isHostsPagePresented { isHostsPagePresented = false }
  }

  /// 主机页「复制 SSH 命令」：生成与回退引擎相同的 `ssh <target>` 文本写入剪贴板。
  func copySSHCommand(hostID: UUID) {
    do {
      let target = try MachineFleetModel.openSSHTarget(forHost: hostID, in: SSHHostDirectory.shared.hosts)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(NativeSSHPaneLaunch.typedSSHCommand(target: target), forType: .string)
      notice = L("已复制 SSH 命令")
    } catch {
      notice = L("主机配置无法解析：\(String(describing: error))")
    }
  }

  /// 主机页「从 ~/.ssh/config 导入」：后台解析，合并进导入组，结果用提示告知。
  func importHostsFromSSHConfig() {
    Task { @MainActor [weak self] in
      do {
        let listing = try await SSHBrokerSupervisor.shared.configListing()
        let result = try SSHHostDirectory.shared.mergeSSHConfig(listing)
        self?.notice = L(
          "已从 ~/.ssh/config 导入：新增 \(String(result.added)) 台，更新 \(String(result.updated)) 台")
      } catch {
        self?.notice = L("无法导入 ~/.ssh/config：\(SSHHostEditing.describe(error))")
      }
    }
  }
}
