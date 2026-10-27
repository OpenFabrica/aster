// tools-state.json：容错解码、编码往返、使用记录上限与 frecency。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolState")
struct ToolStateTests {
  /// 从 JSON 文本解码状态文件。
  private func decode(_ json: String) throws -> ToolStateFile {
    try JSONDecoder().decode(ToolStateFile.self, from: Data(json.utf8))
  }

  /// 空对象与缺字段取默认值。
  @Test func missingFieldsUseDefaults() throws {
    #expect(try decode("{}") == ToolStateFile())
    let state = try decode(#"{"plugins": {"com.a.b": {}}}"#)
    #expect(state.plugins["com.a.b"] == ToolPluginState())
  }

  /// 坏字段取默认值、坏记录逐条丢弃、不认识的权限丢弃，其余数据保留。
  @Test func corruptPartsAreDroppedIndividually() throws {
    let state = try decode(
      #"""
      {
        "version": "x",
        "plugins": {
          "com.good.one": {"enabled": false, "grantedPermissions": ["exec", "camera", "exec", 3],
                           "grantedNetworkDomains": ["a.com", 1], "approvedDigest": "abc", "approvedVersion": 2},
          "com.bad.one": "nope"
        },
        "developmentFolders": ["/a", 5, "/b", "/a", ""],
        "usage": {"records": {
          "com.good.one/x": {"count": 3, "lastUsed": 1800000000},
          "com.good.one/y": {"count": 0, "lastUsed": 1800000000},
          "com.good.one/z": {"count": "many"},
          "com.good.one/iso": {"count": 1, "lastUsed": "2027-01-15T08:00:00Z"}
        }}
      }
      """#)
    #expect(state.version == ToolStateFile.currentVersion)
    #expect(state.plugins.keys.sorted() == ["com.good.one"])
    let plugin = try #require(state.plugins["com.good.one"])
    #expect(!plugin.enabled)
    #expect(plugin.grantedPermissions == [.exec])
    #expect(plugin.grantedNetworkDomains == ["a.com"])
    #expect(plugin.approvedDigest == "abc")
    #expect(plugin.approvedVersion == nil)
    #expect(state.developmentFolders == ["/a", "/b"])
    #expect(state.usage.records.keys.sorted() == ["com.good.one/iso", "com.good.one/x"])
    #expect(state.usage.records["com.good.one/iso"]?.lastUsed == Date(timeIntervalSince1970: 1_800_000_000))
  }

  /// 整个字段类型不对时退回默认值，不让整份文件失败。
  @Test func wrongContainerTypesFallBack() throws {
    let state = try decode(#"{"plugins": [], "developmentFolders": {}, "usage": 3}"#)
    #expect(state == ToolStateFile())
  }

  /// 编码再解码得到同一份状态；日期固定写成 Unix 秒，不受编码器日期策略影响。
  @Test func encodingRoundTripsRegardlessOfDateStrategy() throws {
    var state = ToolStateFile(developmentFolders: ["/dev/plugin"])
    state.plugins["com.a.b"] = ToolPluginState(
      enabled: true, grantedPermissions: [.network], grantedNetworkDomains: ["*.a.com"], approvedDigest: "d",
      approvedVersion: "1.0.0")
    state.usage.recordUse("com.a.b/x", at: Date(timeIntervalSince1970: 1_800_000_000.5))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    #expect(try decoder.decode(ToolStateFile.self, from: try encoder.encode(state)) == state)
    let json = String(decoding: try JSONEncoder().encode(state.usage), as: UTF8.self)
    #expect(json.contains("1800000000.5"))
  }

  /// 记录超过上限时淘汰最久没用的，但不淘汰刚记的那条（即使时钟回拨让它显得最旧）。
  @Test func recordLimitEvictsOldestButKeepsNewest() {
    var usage = ToolUsageStats()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    for index in 0..<ToolUsageStats.maximumRecords {
      usage.recordUse("p/\(index)", at: base.addingTimeInterval(TimeInterval(index)))
    }
    usage.recordUse("p/new", at: base.addingTimeInterval(10_000))
    #expect(usage.records.count == ToolUsageStats.maximumRecords)
    #expect(usage.records["p/0"] == nil)
    usage.recordUse("p/skewed", at: base.addingTimeInterval(-10_000))
    #expect(usage.records.count == ToolUsageStats.maximumRecords)
    #expect(usage.records["p/skewed"] != nil)
    #expect(usage.records["p/1"] == nil)
  }

  /// 手改后超过上限的记录在解码时裁剪。
  @Test func decodingPrunesExcessRecords() throws {
    let records = (0..<(ToolUsageStats.maximumRecords + 5)).map { #""p/\#($0)": {"count": 1, "lastUsed": \#(1_800_000_000 + $0)}"# }
    let usage = try JSONDecoder().decode(ToolUsageStats.self, from: Data(#"{"records": {\#(records.joined(separator: ","))}}"#.utf8))
    #expect(usage.records.count == ToolUsageStats.maximumRecords)
    #expect(usage.records["p/4"] == nil)
    #expect(usage.records["p/5"] != nil)
  }

  /// frecency：次数 × 7 天半衰期；没用过为 0，未来时间按现在算；按插件删除记录。
  @Test func frecencyAndRemoval() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var usage = ToolUsageStats()
    for _ in 0..<4 { usage.recordUse("com.a.b/x", at: now.addingTimeInterval(-7 * 86_400)) }
    usage.recordUse("com.a.b/future", at: now.addingTimeInterval(3_600))
    usage.recordUse("com.c.d/x", at: now)
    #expect(abs(usage.frecency("com.a.b/x", now: now) - 2) < 1e-9)
    #expect(usage.frecency("com.a.b/future", now: now) == 1)
    #expect(usage.frecency("missing", now: now) == 0)
    usage.removeRecords(forPluginID: "com.a.b")
    #expect(usage.records.keys.sorted() == ["com.c.d/x"])
  }
}
