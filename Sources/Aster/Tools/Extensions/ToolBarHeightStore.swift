// 状态条拉高后的高度按窗口记住：与 `WorkspacePanelLayoutStore` 一样存进该窗口 `AppModel` 的 UserDefaults suite，
// 关闭附加窗口清理 suite 时随之清除。纯值与夹取规则在 AsterCore `ToolBarHeights` / `ToolBarHeightPolicy`。
import AsterCore
import Foundation
import os

/// 单个工作区窗口的条高仓库。只在主线程使用。
@MainActor
final class ToolBarHeightStore {
  static let persistenceKey = "aster.workspace.tool-bar-heights.v1"
  private static let logger = Logger(subsystem: "io.local.aster-terminal", category: "tool-bars")

  private(set) var heights: ToolBarHeights
  private let defaults: UserDefaults

  /// 读出已存的高度；数据损坏时回到空（每条单行），下次写入覆盖。
  init(defaults: UserDefaults) {
    self.defaults = defaults
    guard let data = defaults.data(forKey: Self.persistenceKey) else {
      heights = ToolBarHeights()
      return
    }
    do {
      heights = try JSONDecoder().decode(ToolBarHeights.self, from: data)
    } catch {
      Self.logger.notice("tool bar heights unreadable, falling back to defaults: \(error.localizedDescription)")
      heights = ToolBarHeights()
    }
  }

  /// 某个位置记住的高度（未缩放点）；由条按行高吸附、夹取。
  func height(for slot: ToolViewSlot) -> Double? { heights.height(for: slot) }

  /// 记住某个位置的高度并立即写盘；没变化不写。
  func setHeight(_ height: Double, for slot: ToolViewSlot) {
    var updated = heights
    updated.setHeight(height, for: slot)
    guard updated != heights else { return }
    heights = updated
    do {
      defaults.set(try JSONEncoder().encode(heights), forKey: Self.persistenceKey)
    } catch {
      Self.logger.error("tool bar heights not saved: \(error.localizedDescription)")
    }
  }
}
