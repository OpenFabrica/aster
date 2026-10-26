// 「已知主机」子页的内容推导（纯函数）：覆盖主机的说明、删除选项、搜索与文件徽章。
import AsterCore
import Testing

@testable import Aster

@Test("已知主机内容：hashed 记录写出匹配到的主机名；明文多主机行只补已保存主机名；端口写成 [host]:port")
@MainActor
func knownHostsPageContentDescribesEntries() throws {
  let entries = knownHostsPageListing().entries
  let names: (SSHHostPort) -> [String] = { $0.host == "172.16.10.146" ? ["app-server"] : [] }
  #expect(
    KnownHostsPageContent.title(for: entries[1], names: names)
      == L("（已哈希）") + " — " + L("匹配：\("app-server（172.16.10.146）")"))
  #expect(KnownHostsPageContent.title(for: entries[2], names: names) == "web.example.com, 10.0.0.5")
  // 明文行只补已保存主机名，不重复地址。
  #expect(KnownHostsPageContent.title(for: entries[3], names: { _ in ["monite"] }) == "[monite.internal]:2222 — monite")
  #expect(KnownHostsPageContent.endpointText(SSHHostPort(host: "monite.internal", port: 2222)) == "[monite.internal]:2222")
  #expect(KnownHostsPageContent.covered(by: entries[1]) == ["172.16.10.146"])
  #expect(KnownHostsPageContent.covered(by: entries[2]) == ["web.example.com", "10.0.0.5"])
  // 单主机行只有删整行；多主机行可以只删其中一台。
  #expect(KnownHostsPageContent.deleteChoices(for: entries[0]) == [.line])
  #expect(
    KnownHostsPageContent.deleteChoices(for: entries[2])
      == [.line, .host(SSHHostPort(host: "web.example.com", port: 22)), .host(SSHHostPort(host: "10.0.0.5", port: 22))])
  // 搜索覆盖已保存主机名、指纹片段与算法，不区分大小写。
  #expect(KnownHostsPageContent.matches(entries[1], query: "APP-server", names: names))
  #expect(KnownHostsPageContent.matches(entries[0], query: "zisF", names: names))
  #expect(!KnownHostsPageContent.matches(entries[0], query: "ecdsa", names: names))

  let files = knownHostsPageListing().files
  #expect(KnownHostsPageContent.badges(for: files[0]).isEmpty)
  #expect(KnownHostsPageContent.badges(for: files[1]) == [L("文件不存在")])
  #expect(KnownHostsPageContent.badges(for: files[2]) == [L("系统级 · 只读")])
}

@Test("已知主机分页内容：跨文件顺序稳定、不漏不重；边界页码、空列表和全量搜索")
@MainActor
func knownHostsPageContentPaginatesAcrossFiles() {
  var listing = paginatedKnownHostsListing(count: 123)
  let firstFile = listing.files[0]
  let secondFile = SSHKnownHostsListing.File(path: "/tmp/second-known-hosts", exists: true, writable: false, global: true)
  listing.entries = listing.entries.map { entry in
    var copy = entry
    if entry.line > 30 { copy.file = secondFile.path }
    return copy
  }
  listing.files = [secondFile, firstFile]
  var renderedLines: [Int] = []
  var describedRows = 0
  for index in 0..<3 {
    let page = KnownHostsPageContent.page(listing: listing, query: "", index: index,
      names: { _ in [] }, isRemovable: { entry in
        describedRows += 1
        return entry.file == firstFile.path
      })
    #expect(page.total == 123 && page.count == 3 && page.index == index)
    let rows = page.sections.flatMap(\.rows)
    #expect(rows.count == (index == 2 ? 23 : 50))
    renderedLines += rows.map(\.entry.line)
    #expect(rows.filter { $0.entry.file == secondFile.path }.allSatisfy { !$0.removable })
  }
  #expect(renderedLines == Array(31...123) + Array(1...30))
  #expect(describedRows == 123) // 只构造这三页实际显示的行，没有反复构造完整列表。
  let searched = KnownHostsPageContent.page(listing: listing, query: "host-75.example.com", index: 999,
    names: { _ in [] }, isRemovable: { _ in false })
  #expect(searched.index == 0 && searched.total == 1 && searched.count == 1)
  #expect(searched.sections.flatMap(\.rows).map(\.entry.line) == [75])
  let negative = KnownHostsPageContent.page(listing: listing, query: "", index: -1,
    names: { _ in [] }, isRemovable: { _ in false })
  #expect(negative.index == 0)
  let last = KnownHostsPageContent.page(listing: listing, query: "", index: 999,
    names: { _ in [] }, isRemovable: { _ in false })
  #expect(last.index == 2 && last.sections.flatMap(\.rows).count == 23)
  let empty = KnownHostsPageContent.page(listing: .init(), query: "", index: 5,
    names: { _ in [] }, isRemovable: { _ in false })
  #expect(empty.index == 0 && empty.count == 1 && empty.total == 0 && empty.sections.isEmpty)
}
