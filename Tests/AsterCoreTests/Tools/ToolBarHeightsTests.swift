// 状态条拉高的纯规则：可拖高的位置、按整行吸附与上限、按位置记住的高度编解码与过滤。
import AsterCore
import Foundation
import Testing

@Suite("插件状态条高度")
struct ToolBarHeightsTests {
  @Test("只有 tab.*、window.bottom、pane.bottom 与 activePane.bottom 可以拖高")
  func resizableSlots() {
    let resizable = ToolViewSlot.allCases.filter(ToolBarHeightPolicy.isResizable)
    #expect(Set(resizable) == [.tabTop, .tabBottom, .windowBottom, .paneBottom, .activePaneBottom])
  }

  @Test("上限是 8 行与 240pt 取小，至少 1 行")
  func maximumRowsIsEightOr240Points() {
    #expect(ToolBarHeightPolicy.maximumRows(rowHeight: 26) == 8)
    #expect(ToolBarHeightPolicy.maximumRows(rowHeight: 40) == 6)
    #expect(ToolBarHeightPolicy.maximumRows(rowHeight: 300) == 1)
    #expect(ToolBarHeightPolicy.maximumRows(rowHeight: 0) == 1)
    #expect(ToolBarHeightPolicy.maximumRows(rowHeight: 26, maximumHeight: 100) == 3)
  }

  @Test("任意高度吸附成整行（过半行才进位）并夹到 1…上限；坏值回到单行")
  func rowsSnapAndClamp() {
    #expect(ToolBarHeightPolicy.rows(forHeight: 38, rowHeight: 26) == 1)
    #expect(ToolBarHeightPolicy.rows(forHeight: 39, rowHeight: 26) == 2)
    #expect(ToolBarHeightPolicy.rows(forHeight: 78, rowHeight: 26) == 3)
    #expect(ToolBarHeightPolicy.rows(forHeight: 0, rowHeight: 26) == 1)
    #expect(ToolBarHeightPolicy.rows(forHeight: -50, rowHeight: 26) == 1)
    #expect(ToolBarHeightPolicy.rows(forHeight: 10_000, rowHeight: 26) == 8)
    #expect(ToolBarHeightPolicy.rows(forHeight: .nan, rowHeight: 26) == 1)
    #expect(ToolBarHeightPolicy.rows(forHeight: .infinity, rowHeight: 26) == 1)
    #expect(ToolBarHeightPolicy.clampedHeight(90, rowHeight: 26) == 78)
  }

  @Test("编码成扁平字典；解码丢掉未知位置、不可拖高的位置与非正值")
  func codingFiltersInvalidEntries() throws {
    var heights = ToolBarHeights()
    heights.setHeight(78, for: .tabBottom)
    heights.setHeight(48, for: .paneBottom)
    heights.setHeight(56, for: .windowTop)
    #expect(heights.values == ["tab.bottom": 78, "pane.bottom": 48])
    let data = try JSONEncoder().encode(heights)
    #expect(try JSONDecoder().decode([String: Double].self, from: data) == ["tab.bottom": 78, "pane.bottom": 48])
    #expect(try JSONDecoder().decode(ToolBarHeights.self, from: data) == heights)

    let raw = Data(#"{"tab.top": 52, "window.top": 56, "nope": 30, "window.bottom": -1, "pane.bottom": 0}"#.utf8)
    #expect(try JSONDecoder().decode(ToolBarHeights.self, from: raw).values == ["tab.top": 52])
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ToolBarHeights.self, from: Data("[1]".utf8)) }

    heights.setHeight(nil, for: .tabBottom)
    heights.setHeight(.nan, for: .paneBottom)
    #expect(heights.values.isEmpty)
  }
}
