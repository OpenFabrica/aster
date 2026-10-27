// 搜索性能：300 个条目（中英文混合、带拼音）在缓存预热后应在毫秒级完成。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolMatcherPerformance")
struct ToolMatcherPerformanceTests {
  /// 30 个插件 × 10 个功能，标题、副标题、关键词中英文混合。
  private static func catalog() -> [ToolCatalogEntry] {
    let chinese = ["时间戳转换", "格式化文本", "随机密码生成", "端口占用查询", "图片压缩", "颜色选择器", "正则测试", "差异比较", "二维码", "哈希计算"]
    let english = ["Timestamp", "Formatter", "Password", "Ports", "Image", "Color", "Regex", "Diff", "QR Code", "Hash"]
    return (0..<30).flatMap { plugin in
      (0..<10).map { index in
        ToolMatcherFixture.entry(
          plugin: "com.example.p\(plugin)", name: "Plugin \(plugin) 插件",
          code: "f\(index)", title: "\(chinese[index]) \(plugin)",
          subtitle: "\(english[index]) tool number \(plugin) · 第 \(plugin) 号",
          keywords: [english[index].lowercased(), "kw\(plugin)", "工具"])
      }
    }
  }

  /// 预热后多次搜索取中位数；阈值放宽到调试构建也稳定通过，实际在 1–2 个数量级之下。
  @Test func searchingThreeHundredEntriesIsFast() {
    let entries = Self.catalog()
    #expect(entries.count == 300)
    let queries = ["sjc", "shijian", "format", "密码", "port 12", "gs", "xyz", "color", "hash 2", "tool"]
    let usage = ToolUsageStats()
    let now = ToolMatcherFixture.now
    for query in queries { _ = ToolMatcher.search(query, entries: entries, usage: usage, now: now, limit: 20) }
    let clock = ContinuousClock()
    var durations: [Duration] = []
    for _ in 0..<3 {
      for query in queries {
        durations.append(clock.measure { _ = ToolMatcher.search(query, entries: entries, usage: usage, now: now, limit: 20) })
      }
    }
    let median = durations.sorted()[durations.count / 2]
    #expect(median < .milliseconds(100), "median \(median)")
    #expect(!ToolMatcher.search("sjc", entries: entries, usage: usage, now: now, limit: 20).isEmpty)
  }
}
