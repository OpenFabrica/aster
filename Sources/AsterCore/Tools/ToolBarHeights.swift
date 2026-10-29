// 插件状态条拉高的纯规则与持久化值：哪些位置可以拖高、按整行吸附的行数上下限，
// 以及按挂载点记住的高度（JSON 字典，未缩放点）。存取在应用层 `ToolBarHeightStore`。
import Foundation

/// 状态条拉高的规则。单位不限（调用方统一用未缩放点或缩放后的点），只要行高与上限同一单位。
public enum ToolBarHeightPolicy {
  /// 最多显示几行。
  public static let maximumRows = 8
  /// 高度上限（点）。行高很大时它比 8 行先到。
  public static let maximumHeight: Double = 240

  /// 能拖高的位置。`window.top` 与红绿灯同一行、高度由窗口决定；`sidebar.section` 是纵向列表；`pane.header` 固定一行（和 `window.top` 一样不拖高）。
  public static func isResizable(_ slot: ToolViewSlot) -> Bool {
    switch slot {
    case .tabTop, .tabBottom, .windowBottom, .paneBottom, .activePaneBottom: true
    case .windowTop, .sidebarSection, .paneHeader, .inspectorPanel: false
    }
  }

  /// 某个行高下最多几行：8 行与 `maximumHeight` 取小，至少 1 行。
  public static func maximumRows(rowHeight: Double, maximumHeight: Double = maximumHeight) -> Int {
    guard rowHeight > 0, rowHeight.isFinite, maximumHeight.isFinite else { return 1 }
    return max(1, min(maximumRows, Int((maximumHeight / rowHeight).rounded(.down))))
  }

  /// 把任意高度吸附成整行数并夹到 1…上限。非有限值（坏数据）回到单行。
  public static func rows(forHeight height: Double, rowHeight: Double, maximumHeight: Double = maximumHeight) -> Int {
    guard height.isFinite, rowHeight > 0, rowHeight.isFinite else { return 1 }
    let rows = Int((height / rowHeight).rounded())
    return min(max(1, rows), maximumRows(rowHeight: rowHeight, maximumHeight: maximumHeight))
  }

  /// 吸附并夹取后的高度（行数 × 行高）。
  public static func clampedHeight(_ height: Double, rowHeight: Double, maximumHeight: Double = maximumHeight) -> Double {
    Double(rows(forHeight: height, rowHeight: rowHeight, maximumHeight: maximumHeight)) * rowHeight
  }
}

/// 每个挂载点记住的条高（未缩放点）。编码成 `{"tab.bottom": 78}` 这样的扁平字典；
/// 未知位置、不可拖高的位置与非正 / 非有限值在初始化时丢弃。`pane.bottom` 所有 Pane 共用一个值。
public struct ToolBarHeights: Codable, Equatable, Sendable {
  public private(set) var values: [String: Double]

  /// 只保留可拖高位置上的有效值。
  public init(values: [String: Double] = [:]) {
    self.values = values.filter { key, value in
      guard let slot = ToolViewSlot(rawValue: key) else { return false }
      return ToolBarHeightPolicy.isResizable(slot) && value.isFinite && value > 0
    }
  }

  /// 按扁平字典解码，再走初始化的过滤。
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(values: try container.decode([String: Double].self))
  }

  /// 编码成扁平字典。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(values)
  }

  /// 某个位置记住的高度；没记过为 nil。
  public func height(for slot: ToolViewSlot) -> Double? { values[slot.rawValue] }

  /// 记住（或用 nil 忘掉）某个位置的高度。不可拖高的位置与无效值忽略。
  public mutating func setHeight(_ height: Double?, for slot: ToolViewSlot) {
    guard ToolBarHeightPolicy.isResizable(slot) else { return }
    guard let height, height.isFinite, height > 0 else {
      values[slot.rawValue] = nil
      return
    }
    values[slot.rawValue] = height
  }
}
