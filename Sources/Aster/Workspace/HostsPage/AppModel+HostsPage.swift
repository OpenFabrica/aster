import AppKit
import AsterCore
import Foundation

// 侧栏「主机」页的显隐与主机动作。页面状态只是本窗口内容区显示什么，不持久化；
// 主机数据的唯一权威仍是 `SSHHostDirectory`，这里只调用它与已有的 SSH 打开入口。

extension AppModel {
  /// 在内容区显示主机页。命令面板与侧栏「主机」行共用。
  func presentHostsPage() {
    // 浮层与主机页抢同一块注意力：打开主机页时收起它们，避免搜索框被盖住。
    if isPalettePresented { isPalettePresented = false }
    if isOpenQuicklyPresented { isOpenQuicklyPresented = false }
    if !isHostsPagePresented { isHostsPagePresented = true }
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

  /// 主机页「复制」：复制出一台「<名称> 副本」，规则与设置页相同。
  func duplicateHost(hostID: UUID) {
    let directory = SSHHostDirectory.shared
    guard let source = directory.host(hostID), !source.isDefaults else {
      notice = L("主机不存在。")
      return
    }
    do {
      try directory.upsert(source.duplicated(name: L("\(source.name) 副本")))
    } catch {
      notice = SettingsHostsBridge.describe(error)
    }
  }

  /// 主机页「删除…」：确认后删除，并按设置页同一规则清理钥匙串口令。
  func confirmAndDeleteHost(hostID: UUID, in window: NSWindow?) {
    let directory = SSHHostDirectory.shared
    guard let profile = directory.host(hostID), !profile.isDefaults else { return }
    let alert = NSAlert()
    alert.messageText = L("删除主机“\(HostBrowserCatalog.title(for: profile))”？")
    alert.informativeText = L("删除后无法恢复。引用它作跳板的主机会改为直连。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("删除"))
    alert.addButton(withTitle: L("取消"))
    let perform: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.deleteHost(hostID: hostID)
    }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: perform)
    } else {
      perform(alert.runModal())
    }
  }

  /// 执行删除；失败只给提示，主机列表由目录发布的变化自动刷新。
  private func deleteHost(hostID: UUID) {
    do {
      if let passwordError = try SSHHostRemoval.remove(
        hostID, from: .shared, passwords: SSHCredentialStore())
      {
        notice = L("主机已删除，但没能从钥匙串删除口令：\(SettingsHostsBridge.describe(passwordError))")
      }
    } catch {
      notice = SettingsHostsBridge.describe(error)
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
        self?.notice = L("无法导入 ~/.ssh/config：\(SettingsHostsBridge.describe(error))")
      }
    }
  }
}
