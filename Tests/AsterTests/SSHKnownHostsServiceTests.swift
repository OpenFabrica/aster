import AsterCore
import Foundation
import Testing

@testable import Aster

// 「已知主机」App 侧服务：加载代次、删除校验、同一时刻只删一次、结果提示与删除后重新列出。
// 网页快照形状见 `SettingsKnownHostsBridgeTests`，原生页面见 `KnownHostsPageViewControllerTests`。

/// 可控的假 aster-ssh：列表可以挂起，便于验证较早的结果不会覆盖较新的结果。
actor KnownHostsServiceFakeTool {
  var listings: [SSHKnownHostsListing] = []
  var listError: Error?
  var removeError: Error?
  private(set) var listCount = 0
  private(set) var removeRequests: [SSHKnownHostsRemoveRequest] = []

  /// 依次返回的列表；用完后重复最后一份。
  func setListings(_ values: [SSHKnownHostsListing]) { listings = values }
  /// 列出时抛出的错误；nil 表示成功。
  func setListError(_ error: Error?) { listError = error }
  /// 删除时抛出的错误；nil 表示成功。
  func setRemoveError(_ error: Error?) { removeError = error }

  /// 记录次数并返回下一份列表。
  func list(_ request: SSHKnownHostsListRequest) throws -> SSHKnownHostsListing {
    listCount += 1
    if let listError { throw listError }
    return listings.isEmpty ? SSHKnownHostsListing() : listings[min(listCount - 1, listings.count - 1)]
  }

  /// 记录请求，按预设成功或失败。
  func remove(_ request: SSHKnownHostsRemoveRequest) throws -> SSHKnownHostsRemoveResult {
    removeRequests.append(request)
    if let removeError { throw removeError }
    return SSHKnownHostsRemoveResult(removed: request.host == nil ? "line" : "pattern")
  }

  /// 接到服务上的依赖。
  nonisolated var dependencies: SSHKnownHostsService.Dependencies {
    .init(list: { try await self.list($0) }, remove: { try await self.remove($0) })
  }
}

/// 一份含可写默认文件、多主机行与只读系统文件的列表。
func knownHostsServiceSample() -> SSHKnownHostsListing {
  SSHKnownHostsListing(
    files: [
      .init(path: "/tmp/kh/known_hosts", exists: true, writable: true, global: false),
      .init(path: "/etc/ssh/ssh_known_hosts", exists: true, writable: false, global: true),
    ],
    entries: [
      .init(
        file: "/tmp/kh/known_hosts", line: 1, hosts: ["web.example.com", "10.0.0.5"],
        algorithm: "ssh-ed25519", fingerprint: "SHA256:abc",
        matches: [SSHHostPort(host: "10.0.0.5", port: 22)], lineDigest: "d1"),
      .init(
        file: "/etc/ssh/ssh_known_hosts", line: 3, hosts: ["(hashed)"], hashed: true,
        algorithm: "ssh-rsa", fingerprint: "SHA256:def", lineDigest: "d2"),
    ])
}

/// 等到条件成立（最多约 3 秒）。
@MainActor
func knownHostsWait(_ condition: () -> Bool) async {
  for _ in 0..<300 where !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

@Test("已知主机服务：列表加载后可查主机名与可删标记；列出失败转成一句话并保留旧列表")
@MainActor
func knownHostsServiceLoadsAndKeepsListingOnFailure() async throws {
  let fake = KnownHostsServiceFakeTool()
  await fake.setListings([knownHostsServiceSample()])
  let web = SSHHostProfile(name: "web", host: "10.0.0.5")
  let service = SSHKnownHostsService(
    dependencies: fake.dependencies, hosts: { [.emptyDefaults(), web] }, machineTargets: { [] })
  var changes = 0
  service.didChange = { changes += 1 }
  #expect(service.state == .idle)

  #expect(await withCheckedContinuation { done in service.refresh { done.resume(returning: $0) } })
  #expect(service.state == .loaded && changes == 2)
  let listing = try #require(service.listing)
  #expect(service.names(for: SSHHostPort(host: "10.0.0.5", port: 22)) == ["web"])
  #expect(service.isRemovable(listing.entries[0]))
  #expect(!service.isRemovable(listing.entries[1]))

  await fake.setListError(SSHBrokerError.executableMissing)
  #expect(await withCheckedContinuation { done in service.refresh { done.resume(returning: $0) } } == false)
  #expect(service.state == .failed(L("找不到 aster-ssh，请重新构建 Aster.app")))
  #expect(service.listing == listing)
}

@Test("已知主机服务：删除前按上一次列表校验文件可写、行与摘要一致、主机是命中项")
@MainActor
func knownHostsServiceValidatesRemoval() async throws {
  let fake = KnownHostsServiceFakeTool()
  await fake.setListings([knownHostsServiceSample()])
  let service = SSHKnownHostsService(dependencies: fake.dependencies, hosts: { [] }, machineTargets: { [] })
  let line = SSHKnownHostsRemoveRequest(file: "/tmp/kh/known_hosts", line: 1, lineDigest: "d1")
  #expect(throws: SSHKnownHostsError.unknownEntry) { try service.validated(line) }

  service.refresh()
  await knownHostsWait { service.state == .loaded }
  #expect(try service.validated(line) == line)
  var host = line
  host.host = SSHHostPort(host: "10.0.0.5", port: 22)
  #expect(try service.validated(host) == host)
  host.host = SSHHostPort(host: "web.example.com", port: 22)  // 明文模式但不在命中列表里
  #expect(throws: SSHKnownHostsError.unknownEntry) { try service.validated(host) }
  #expect(throws: SSHKnownHostsError.notWritable) {
    try service.validated(.init(file: "/etc/ssh/ssh_known_hosts", line: 3, lineDigest: "d2"))
  }
  #expect(throws: SSHKnownHostsError.unknownEntry) {
    try service.validated(.init(file: "/tmp/kh/known_hosts", line: 1, lineDigest: "stale"))
  }
}

@Test("已知主机服务：删除成功提示并重新列出；进行中再删被忽略；stale 提示错误并重新列出")
@MainActor
func knownHostsServiceRemovesOnceAndReloads() async throws {
  let fake = KnownHostsServiceFakeTool()
  await fake.setListings([knownHostsServiceSample()])
  let service = SSHKnownHostsService(dependencies: fake.dependencies, hosts: { [] }, machineTargets: { [] })
  var toasts: [(String, Bool)] = []
  service.toast = { toasts.append(($0, $1)) }
  service.refresh()
  await knownHostsWait { service.state == .loaded }

  let request = SSHKnownHostsRemoveRequest(file: "/tmp/kh/known_hosts", line: 1, lineDigest: "d1")
  var results: [Bool] = []
  service.remove(request) { results.append($0) }
  #expect(service.isRemoving)
  service.remove(request) { results.append($0) }  // 第二次直接拒绝，不会发出请求
  await knownHostsWait { results.count == 2 && service.state == .loaded }
  #expect(results == [false, true])
  #expect(await fake.removeRequests == [request])
  #expect(await fake.listCount == 2)
  #expect(toasts.map(\.1) == [false])

  await fake.setRemoveError(SSHKnownHostsToolError.stale)
  service.remove(request)
  await knownHostsWait { toasts.count == 2 && service.state == .loaded && !service.isRemoving }
  #expect(toasts.last?.0 == L("这条记录已在别处被修改，列表已重新加载"))
  #expect(toasts.last?.1 == true)
  #expect(await fake.listCount == 3)
}

@Test("已知主机服务：较早发起、较晚返回的列表不覆盖较新的结果")
@MainActor
func knownHostsServiceDropsOutdatedListing() async throws {
  var newer = knownHostsServiceSample()
  newer.entries.removeLast()
  let calls = Counter()
  // 第一次列出故意慢返回，第二次立即返回：第一次的结果到达时代次已过期。
  let dependencies = SSHKnownHostsService.Dependencies(
    list: { [newer] _ in
      if await calls.next() == 1 {
        try await Task.sleep(for: .milliseconds(200))
        return knownHostsServiceSample()
      }
      return newer
    },
    remove: { _ in SSHKnownHostsRemoveResult(removed: "line") })
  let service = SSHKnownHostsService(dependencies: dependencies, hosts: { [] }, machineTargets: { [] })
  var first: Bool?
  service.refresh { first = $0 }
  service.refresh()
  await knownHostsWait { first != nil }
  #expect(first == false)
  #expect(service.state == .loaded)
  #expect(service.listing == newer)
}

/// 线程安全的调用计数。
private actor Counter {
  private var value = 0
  /// 加一并返回新值。
  func next() -> Int {
    value += 1
    return value
  }
}

@Test("已知主机服务：aster-ssh 的错误名转成用户能看懂的话")
@MainActor
func knownHostsServiceDescribesErrors() {
  #expect(SSHKnownHostsService.describe(SSHKnownHostsToolError.failed("global")) == L("系统级 known_hosts 文件是只读的"))
  #expect(SSHKnownHostsService.describe(SSHKnownHostsToolError.failed("noMatch")) == L("这一行里没有这台主机"))
  #expect(SSHKnownHostsService.describe(SSHRuntimeToolError.timedOut) == L("读取 known_hosts 超时"))
  #expect(SSHKnownHostsService.describe(SSHKnownHostsError.notWritable) == L("这个 known_hosts 文件不可写"))
  #expect(SSHKnownHostsService.displayPath(NSHomeDirectory() + "/.ssh/known_hosts") == "~/.ssh/known_hosts")
}
